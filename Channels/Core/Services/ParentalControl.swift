//
//  ParentalControl.swift
//  Channels
//
//  Local parental-control state: an on/off flag and a 6-digit PIN. When on,
//  opening the 18+ category requires the PIN, and turning the control off
//  requires the PIN. Stored on-device (UserDefaults).
//

import Foundation
import Combine

@MainActor
final class ParentalControl: ObservableObject {
    static let shared = ParentalControl()

    private let d = UserDefaults.standard
    private let enabledKey = "parental.enabled"
    private let pinKey = "parental.pin"

    @Published private(set) var isEnabled: Bool
    // @Published so `hasPin`-driven UI (the "Set"/"Change" label) refreshes.
    @Published private var pin: String?

    /// After a correct PIN, everything stays unlocked until this time (1 min).
    // @Published so a granted unlock re-evaluates `locked` in CategoryChannelsView
    // (under @Observable every stored property was tracked; @Published is explicit).
    @Published private var unlockUntil: Date?
    private let unlockWindow: TimeInterval = 60

    private init() {
        isEnabled = d.bool(forKey: enabledKey)
        pin = d.string(forKey: pinKey)
    }

    var hasPin: Bool { (pin?.count ?? 0) == 6 }

    func setPin(_ newPin: String) {
        pin = newPin
        d.set(newPin, forKey: pinKey)
    }

    func verify(_ candidate: String) -> Bool { pin == candidate }

    func enable() {
        isEnabled = true
        d.set(true, forKey: enabledKey)
    }

    func disable() {
        isEnabled = false
        d.set(false, forKey: enabledKey)
    }

    // MARK: - Gating

    /// A channel the provider flags as restricted (e.g. adult).
    func isRestricted(_ channel: Channel) -> Bool {
        let r = channel.restricted ?? ""
        return !r.isEmpty && r != "0"
    }

    /// True for the adult category (its whole listing is hidden behind the PIN).
    func isAdult(_ category: LiveColumn) -> Bool {
        category.name.trimmingCharacters(in: .whitespaces) == "18+"
    }

    /// Whether the temporary unlock (from a recent correct PIN) is still valid.
    var isTemporarilyUnlocked: Bool {
        guard let unlockUntil else { return false }
        return Date() < unlockUntil
    }

    /// Grant a 1-minute unlock window after a correct PIN.
    func grantTemporaryUnlock() {
        unlockUntil = Date().addingTimeInterval(unlockWindow)
    }

    /// Does playing this channel require the PIN right now?
    func requiresPin(for channel: Channel) -> Bool {
        isEnabled && isRestricted(channel) && !isTemporarilyUnlocked
    }

    /// Does opening this category's listing require the PIN right now?
    func requiresPin(forCategory category: LiveColumn) -> Bool {
        isEnabled && isAdult(category) && !isTemporarilyUnlocked
    }
}
