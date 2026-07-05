//
//  Endpoints.swift
//  Channels
//
//  Typed portal endpoints (doc 03). Base: https://{host}/api/portalCore/<path>
//

import Foundation

enum HTTPMethod: String { case get = "GET", post = "POST", put = "PUT" }

struct Endpoint {
    let path: String
    let method: HTTPMethod
    /// AES-encrypted `{data,len}` body (false = plaintext `needEncrypt:false`).
    let encrypted: Bool

    init(_ path: String, method: HTTPMethod = .post, encrypted: Bool = true) {
        self.path = path
        self.method = method
        self.encrypted = encrypted
    }
}

extension Endpoint {
    // Device activation + keep-alive
    static let active     = Endpoint("v8/active")
    static let heartbeat  = Endpoint("v5/heartbeat")

    // Live catalog
    static let getSlbInfo        = Endpoint("v15/getSlbInfo")
    static let getColumnContents = Endpoint("v3/getColumnContents")
    static let getLiveData       = Endpoint("v6/getLiveData")

    // Playback
    static let startPlayLive = Endpoint("v4/startPlayLive")
}
