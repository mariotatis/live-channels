//
//  DeviceFingerprint.swift
//  Channels
//
//  Builds an iOS-shaped device fingerprint for v3/snToken (doc 02).
//  iOS can't read a real MAC / Android build fields, so we derive stable
//  pseudo values from identifierForVendor (persisted so identity survives).
//

import Foundation
import UIKit

enum DeviceFingerprint {

    /// Stable per-install id (Keychain-persisted UUID → survives reinstalls).
    static var stableId: String {
        if let existing = KeychainStore.shared.string(for: "device.uuid") {
            return existing
        }
        let uuid = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        KeychainStore.shared.set(uuid, for: "device.uuid")
        return uuid
    }

    /// Deterministic pseudo-MAC derived from the stable id.
    static var pseudoMac: String {
        let hex = Array(stableId.replacingOccurrences(of: "-", with: "").uppercased())
        let bytes = stride(from: 0, to: min(12, hex.count), by: 2).map { String(hex[$0...min($0 + 1, hex.count - 1)]) }
        return bytes.prefix(6).joined(separator: ":")
    }

    static var modelIdentifier: String {
        var sys = utsname()
        uname(&sys)
        let mirror = Mirror(reflecting: sys.machine)
        let id = mirror.children.reduce("") { acc, el in
            guard let v = el.value as? Int8, v != 0 else { return acc }
            return acc + String(UnicodeScalar(UInt8(v)))
        }
        return id.isEmpty ? "iPhone" : id
    }

    /// The full SnToken request body (extras are ignored server-side, doc 02).
    static func snTokenBody() -> [String: Any] {
        let osBuild = "iOS \(UIDevice.current.systemVersion)"
        return [
            "androidId": stableId,
            "serialNumber": stableId,
            "brand": "Apple",
            "manufacturer": "Apple",
            "device": modelIdentifier,
            "hardware": modelIdentifier,
            "board": modelIdentifier,
            "model": modelIdentifier,
            "display": osBuild,
            "fingerprint": "Apple/\(modelIdentifier)/\(osBuild)",
            "tags": "release-keys",
            "host": "ios",
            "cpuAbi": "arm64",
            "cpuId": modelIdentifier,
            "diskInfo": "",
            "ramSize": "",
            "romSize": "",
            "verId": AppConfig.authVersion,
            "wifiMac": pseudoMac,
            "etheMac": pseudoMac,
            "gatewayMac": pseudoMac
        ]
    }

    /// The v8/active request body (matches the live app; common params added by PortalClient).
    static func activeBody(snToken: String = "") -> [String: Any] {
        [
            "authCode": "",
            "authVersion": "",
            "channel": "default",
            "macAddr": "02:00:00:00:00:00",
            "matadata": "",
            "openNum": 0,
            "signdata": "",
            "snToken": snToken,
            "portalCode": ""
        ]
    }
}
