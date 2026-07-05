//
//  ActivationService.swift
//  Channels
//
//  Silent device activation: snToken → active → session triple, persisted to
//  Keychain. No login screen, ever (docs 02, 15). Heartbeat keep-alive.
//

import Foundation
import Combine

@MainActor
final class ActivationService: ObservableObject {
    static let shared = ActivationService()

    enum State: Equatable {
        case idle
        case activating
        case active(Session)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var session: Session?
    private var heartbeatTask: Task<Void, Never>?

    private let sessionKey = "session.triple"

    init() {
        // Restore persisted session and wire the client's session provider.
        session = KeychainStore.shared.codable(Session.self, for: sessionKey)
        if let s = session { state = .active(s) }
        PortalClient.shared.setSessionProvider { [weak self] in self?.session }
    }

    var currentSession: Session? { session }

    /// Boot: (re)activate the device. Never surfaces a login form.
    func bootstrap() async {
        await activate()
    }

    /// Runs snToken → active. Never surfaces a login form; failure = neutral error.
    func activate() async {
        state = .activating
        do {
            // This build activates directly (snToken:""), no separate snToken call.
            let activeData: ActiveData = try await PortalClient.shared.call(
                .active, params: DeviceFingerprint.activeBody(), as: ActiveData.self)

            guard let uid = activeData.userId, let token = activeData.userToken,
                  let portal = activeData.portalCodeList?.first?.portalCode else {
                state = .failed("Service unavailable — contact provider.")
                return
            }
            let newSession = Session(sn: AppConfig.capturedSn, snToken: nil,
                                     userId: uid, userToken: token, portalCode: portal,
                                     playlistUrl: activeData.playlistUrl,
                                     heartBeatTime: activeData.heartBeatTime.flatMap { Int($0) },
                                     restrictedStatus: activeData.restrictedStatus,
                                     hasPay: activeData.hasPay, remainingDays: activeData.remainingDays,
                                     customer: activeData.customer, tips: activeData.tips)
            persist(newSession)
            state = .active(newSession)
            startHeartbeat()
        } catch {
            state = .failed(Self.friendlyMessage(for: error))
        }
    }

    /// Translates known backend responses into a clear explanation.
    static func friendlyMessage(for error: Error) -> String {
        let raw = (error as? PortalError)?.errorDescription ?? "\(error)"
        if raw.contains("版本已停止使用") || raw.contains("portal200001") {
            return "This app version is no longer accepted by the provider’s server "
                 + "(version gate). Update the client version in Settings → Backend, "
                 + "or install the current app build, to connect. (Server: 版本已停止使用)"
        }
        return raw
    }

    private func persist(_ s: Session) {
        session = s
        KeychainStore.shared.setCodable(s, for: sessionKey)
    }

    // MARK: - Heartbeat

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        let interval = TimeInterval(session?.heartBeatTime ?? 300)
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard let self else { return }
                do {
                    _ = try await PortalClient.shared.call(.heartbeat, params: [:], as: BaseResult.self)
                } catch {
                    // token-invalid → silently re-activate
                    if case PortalError.server = error { await self.activate() }
                }
            }
        }
    }

}
