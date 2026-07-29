//
//  Session.swift
//  Channels
//
//  Activation / session models (docs 02, 14, 17).
//

import Foundation

struct PortalCode: Codable, Hashable {
    var portalCode: String
    var type: String? = nil
}

/// Activation response — only the fields the app consumes (extra JSON keys are ignored).
struct ActiveData: Codable {
    var userId: String? = nil
    var userToken: String? = nil
    var portalCodeList: [PortalCode]? = nil
    var heartBeatTime: String? = nil
}

/// The persisted session triple + heartbeat cadence, stored in Keychain.
struct Session: Codable, Equatable {
    var sn: String?
    var userId: String
    var userToken: String
    var portalCode: String
    var heartBeatTime: Int?
}
