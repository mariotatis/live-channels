//
//  PlayableStream.swift
//  Channels
//
//  Player-agnostic description of a live stream, built from startPlayLive +
//  getSlbInfo in ContentService.liveStream.
//

import Foundation

struct StreamSource: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let quality: String       // "HD", "4K", "SD"…
    let cdnType: String?
    let avFormat: String?     // hint: "hls", "ts" → informs engine choice
    let license: String?      // DRM (rare)
    var headers: [String: String] = [:]   // Content-Auth / Content-License / App etc.
}

struct PlayableStream: Identifiable {
    let id = UUID()
    let title: String
    let sources: [StreamSource]
    var isLive: Bool = false
    /// The live channel + the columnId it was played from — lets the player
    /// toggle the favorite (and remember how to replay a category-only channel).
    var channel: Channel? = nil
    var columnId: Int? = nil

    var primary: StreamSource? { sources.first }
}
