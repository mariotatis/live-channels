//
//  LiveModels.swift
//  Channels
//
//  Live TV, EPG, catch-up, playback stream models (docs 05, 12, 14).
//

import Foundation

struct GetLiveDataResultData: Codable {
    var channelList: [Channel]? = nil
    var channelListTotalSize: Int? = nil
    var dataVersion: String? = nil
    var expireTimeStr: String? = nil
    var apkNumberSwitch: String? = nil
}

/// getColumnContents(76175) → the live category tree (Deportes, countries, …).
struct LiveColumnContentsResultData: Codable {
    var childColumnList: [LiveColumn]? = nil
    var totalSize: Int? = nil
}

struct LiveColumn: Codable, Identifiable, Hashable {
    var id: Int
    var name: String
    var parentId: Int? = nil
    var sequence: Int? = nil
}

struct Channel: Codable, Identifiable, Hashable {
    var channelCode: String
    var name: String
    var alias: String? = nil
    var channelNumber: Int? = nil
    var fixedChannelNumber: String? = nil
    var showChannelName: String? = nil
    var showIconUrl: String? = nil
    var showPosterUrl: String? = nil
    var posterUrl: String? = nil
    var posterList: [PosterList]? = nil
    var quality: String? = nil
    var isFav: Bool? = nil
    var isLock: Bool? = nil          // parental — IGNORED (no parental wall)
    var restricted: String? = nil
    var keyWords: String? = nil
    var tags: String? = nil
    var supportBusiness: String? = nil
    var supportVideoType: String? = nil
    var liveAddressList: [LiveAddress]? = nil
    var mosaicChannelList: String? = nil

    var id: String { channelCode }

    var logoURL: URL? {
        if let s = showIconUrl, let u = URL(string: s) { return u }
        if let s = showPosterUrl, let u = URL(string: s) { return u }
        if let s = posterUrl, let u = URL(string: s) { return u }
        return posterList?.iconURL ?? posterList?.anyURL
    }

    var displayName: String { showChannelName ?? name }
    var numberLabel: String? { fixedChannelNumber ?? channelNumber.map(String.init) }
}

/// A playable live stream source.
struct LiveAddress: Codable, Hashable {
    var playCode: String? = nil      // stream URL / play code
    var quality: String? = nil
    var cdnType: String? = nil
    var AVFormat: String? = nil      // container/codec hint → informs VLC vs AVPlayer
    var license: String? = nil       // DRM license (if any)
    var tag: String? = nil

    var url: URL? { playCode.flatMap { URL(string: $0) } }
}

struct StartPlayLiveResultData: Codable {
    var name: String? = nil
    var liveAddressList: [LiveAddress]? = nil
}

// MARK: - getSlbInfo CDN / GSLB info (used to build the authed stream URL)

struct SlbInfoData: Codable {
    var cdn_list: [SlbCdn]? = nil
}

struct SlbCdn: Codable {
    var tag: String? = nil          // "live" / "vod" / "record"
    var cdn_type: String? = nil     // matches LiveAddress.cdnType
    var main_addr: String? = nil    // CDN host (may include a /path)
    var url_list: [SlbUrl]? = nil
}

struct SlbUrl: Codable {
    var tag: String? = nil
    var url: String? = nil          // the Content-Auth header value
}
