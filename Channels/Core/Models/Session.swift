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

/// Full activation response (lenient — many fields are stringy).
struct ActiveData: Codable {
    var userId: String? = nil
    var userToken: String? = nil
    var portalCodeList: [PortalCode]? = nil
    var playlistUrl: String? = nil
    var payCoreAddress: String? = nil
    var restrictedStatus: String? = nil
    var childLockPwd: String? = nil
    var heartBeatTime: String? = nil
    var hasPay: String? = nil
    @LenientInt var remainingDays: Int? = nil
    @LenientInt var expRemainingDays: Int? = nil
    var renewFlag: String? = nil
    var customer: String? = nil
    var tips: String? = nil
    var nowTime: String? = nil
    var activeTime: String? = nil
    var getFreeAuthFlag: String? = nil
    var getFreeAuthDays: String? = nil
    var hasFreeAuth: String? = nil
    var vodFreeCount: Int? = nil
}

/// The persisted session triple + housekeeping, stored in Keychain.
struct Session: Codable, Equatable {
    var sn: String?
    var snToken: String?
    var userId: String
    var userToken: String
    var portalCode: String
    var playlistUrl: String?
    var heartBeatTime: Int?
    var restrictedStatus: String?

    // Display-only subscription state (never gates the UI, doc 02).
    var hasPay: String?
    var remainingDays: Int?
    var customer: String?
    var tips: String?
}
