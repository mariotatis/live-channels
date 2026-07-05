//
//  PortalClient.swift
//  Channels
//
//  URLSession + async/await portal client: builds the encrypted {data,len}
//  body, injects the session triple, does main→backup failover, and decrypts
//  + decodes responses (doc 01, 15).
//
//  The project defaults to MainActor isolation; the client is MainActor too for
//  consistency. Network I/O suspends off-main via URLSession's async API.
//

import Foundation

enum PortalError: LocalizedError {
    case noHost
    case badURL
    case transport(Error)
    case http(Int)
    case emptyBody
    case decode(Error)
    case server(code: String?, message: String?)

    var errorDescription: String? {
        switch self {
        case .noHost: return "No portal host configured."
        case .badURL: return "Invalid request URL."
        case .transport(let e): return "Network error: \(e.localizedDescription)"
        case .http(let c): return "Server returned HTTP \(c)."
        case .emptyBody: return "Empty response from server."
        case .decode(let e): return "Could not read server response: \(e)"
        case .server(let code, let msg): return msg ?? "Server error (\(code ?? "?"))."
        }
    }
}

/// Outer portal response: { returnCode, errorMessage, data: hex(base64(3DES(json))) }.
struct OuterResult: Decodable {
    let returnCode: String?
    let errorMessage: String?
    let data: String?
}

@MainActor
final class PortalClient {
    static let shared = PortalClient()

    private let session: URLSession
    private var sessionProvider: (() -> Session?)?

    init(session: URLSession = .shared) {
        self.session = session
    }

    func setSessionProvider(_ provider: @escaping () -> Session?) {
        self.sessionProvider = provider
    }

    /// Common params the app's interceptor injects into every body before
    /// encryption (CONFIRMED from decrypted device capture).
    static func commonBodyParams(session: Session?) -> [String: Any] {
        [
            "loginType": "2",
            "appLanguage": "en",
            "apkVersion": AppConfig.apkVersionBody,
            "sysVersion": AppConfig.spkgVer,
            "appId": AppConfig.apkId,
            "hardwareInfo": "sargo",
            "model": "Pixel 3a",
            "product": "sargo",
            "cpu": "arm64-v8a",
            "B29": "",
            "reserve1": AppConfig.capturedReserve1,
            "deviceToken": "",
            "sn": session?.sn ?? AppConfig.capturedSn,
            "drmId": AppConfig.capturedDrmId,
            "sdkVer": 32
        ]
    }

    // MARK: - Encrypted POST/PUT call

    func call<T: Decodable>(_ endpoint: Endpoint, params: [String: Any] = [:], as type: T.Type) async throws -> T {
        let hosts = [AppConfig.bootstrapPortalHost, AppConfig.backupPortalHost].filter { !$0.isEmpty }
        guard !hosts.isEmpty else { throw PortalError.noHost }

        var lastError: Error = PortalError.noHost
        for host in hosts {
            do {
                return try await performCall(endpoint, host: host, params: params, as: type)
            } catch let e as PortalError {
                if case .transport = e { lastError = e; continue }   // failover only on transport errors
                throw e
            } catch {
                lastError = PortalError.transport(error); continue
            }
        }
        throw lastError
    }

    private func performCall<T: Decodable>(_ endpoint: Endpoint, host: String, params: [String: Any], as type: T.Type) async throws -> T {
        guard let url = URL(string: "\(AppConfig.scheme)://\(host)/\(AppConfig.apiPrefix)/\(endpoint.path)") else {
            throw PortalError.badURL
        }

        // Build the request body: caller params + common params + session triple.
        // The Android client injects these common fields into the JSON *before*
        // encryption via the OkHttp interceptor `zb/b.java` (CONFIRMED).
        var body = params
        let sess = sessionProvider?()
        body.merge(Self.commonBodyParams(session: sess)) { caller, _ in caller }
        if let s = sess {
            body["userId"] = s.userId
            body["userToken"] = s.userToken
            body["portalCode"] = s.portalCode
        }

        // Inject the session triple only for authenticated calls (never for active).
        if let s = sess, endpoint.path != Endpoint.active.path {
            body["userId"] = s.userId
            body["userToken"] = s.userToken
            body["portalCode"] = s.portalCode
        }

        let rawJSON = String(data: try JSONSerialization.data(withJSONObject: body), encoding: .utf8) ?? "{}"

        var request = URLRequest(url: url)
        request.httpMethod = endpoint.method.rawValue
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("okhttp/3.12.12", forHTTPHeaderField: "User-Agent")
        request.setValue(AppConfig.apkId, forHTTPHeaderField: "apk")
        request.setValue(AppConfig.apkVer, forHTTPHeaderField: "apkVer")
        request.setValue(AppConfig.spkgVer, forHTTPHeaderField: "spkgVer")

        // Body = raw string  hex(base64(3DES(json)))  (no {data,len} envelope).
        if endpoint.encrypted {
            request.httpBody = try CryptoBox.encryptBody(rawJSON).data(using: .utf8)
        } else {
            request.httpBody = rawJSON.data(using: .utf8)
        }

        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw PortalError.transport(error)
        }

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw PortalError.http(http.statusCode)
        }
        guard !data.isEmpty else { throw PortalError.emptyBody }

        // Response = { returnCode, errorMessage, data: hex(base64(3DES(json))) }.
        let outer = try JSONDecoder().decode(OuterResult.self, from: data)
        if let code = outer.returnCode, code != "0", !code.isSuccessReturnCode {
            throw PortalError.server(code: code, message: outer.errorMessage)
        }
        guard let enc = outer.data, !enc.isEmpty else { throw PortalError.emptyBody }
        let plain = try CryptoBox.decryptBody(enc)
        guard let plainData = plain.data(using: .utf8) else { throw PortalError.emptyBody }
        do {
            return try JSONDecoder().decode(T.self, from: plainData)
        } catch {
            throw PortalError.decode(error)
        }
    }
}
