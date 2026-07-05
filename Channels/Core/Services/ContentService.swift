//
//  ContentService.swift
//  Channels
//
//  High-level content API. Live TV only — the app is built entirely around the
//  portal's live channel catalog (VOD/movies/shows were dropped because they
//  are delivered over the vendor's proprietary P2P engine, which AVPlayer
//  cannot consume). All calls hit the real portal backend (docs 03–09).
//

import Foundation

@MainActor
final class ContentService {
    static let shared = ContentService()

    private var client: PortalClient { .shared }

    // MARK: - Channels

    /// Flat channel list. Default column (76182) = the full "ChannelList";
    /// pass a category column id to load only that category's channels.
    func liveChannels(columnId: Int = AppConfig.liveColumnId, page: Int = 1) async throws -> [Channel] {
        let params: [String: Any] = ["columnId": columnId, "pageNum": page, "pageSize": 3000,
                                     "dataVersion": "", "expireTimeStr": ""]
        return try await client.call(.getLiveData, params: params, as: GetLiveDataResultData.self).channelList ?? []
    }

    /// The live category tree (Deportes, Cine y Series, countries, NFL/NBA PASS…)
    /// from getColumnContents on the live root column (76175).
    func liveCategories() async throws -> [LiveColumn] {
        let params: [String: Any] = ["columnId": AppConfig.liveCategoryColumnId, "pageNum": 1, "pageSize": 100]
        let cols = try await client.call(.getColumnContents, params: params, as: LiveColumnContentsResultData.self).childColumnList ?? []
        // Drop the flat "ChannelList" pseudo-category (that's the Channels tab).
        return cols.filter { $0.id != AppConfig.liveColumnId }
    }

    // MARK: - Playback

    func startPlayLive(channelCode: String, columnId: Int = AppConfig.liveColumnId) async throws -> [LiveAddress] {
        let params: [String: Any] = ["channelCode": channelCode, "columnId": columnId, "type": "0"]
        return try await client.call(.startPlayLive, params: params, as: StartPlayLiveResultData.self).liveAddressList ?? []
    }

    /// CDN/GSLB addressing for building authed stream URLs.
    func slbInfo() async throws -> SlbInfoData {
        let params: [String: Any] = ["appParams": "", "appVer": AppConfig.apkVersionBody,
                                     "encMediaSupported": 1, "hasPay": "0", "lang": "es",
                                     "liveCodeList": ["masnew_live"], "pipFlag": "0",
                                     "type": "merge", "userIdentity": "1"]
        return try await client.call(.getSlbInfo, params: params, as: SlbInfoData.self)
    }

    /// Builds a playable live stream: `http://<cdn>/live/<playCode>.m3u8` with the
    /// Content-Auth (getSlbInfo) + Content-License (startPlayLive) headers the CDN
    /// requires. CONFIRMED working against the live backend (cdn_type 4 "youshi").
    func liveStream(channel: Channel, columnId: Int = AppConfig.liveColumnId) async throws -> PlayableStream {
        async let addrsCall = startPlayLive(channelCode: channel.channelCode, columnId: columnId)
        async let slbCall = slbInfo()
        let addrs = try await addrsCall
        let slb = try await slbCall
        let liveCdns = (slb.cdn_list ?? []).filter { $0.tag == "live" }
        // Prefer cdn_type 4 (works for external players); fall back to any live cdn.
        guard let cdn = liveCdns.first(where: { $0.cdn_type == "4" }) ?? liveCdns.first,
              let ct = cdn.cdn_type,
              let addr = addrs.first(where: { $0.cdnType == ct }) ?? addrs.first,
              let playCode = addr.playCode,
              let mainAddr = cdn.main_addr,
              let authURL = cdn.url_list?.first?.url else {
            throw PortalError.emptyBody
        }
        let host = mainAddr.replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "https://", with: "").split(separator: "/").first.map(String.init) ?? mainAddr
        guard let url = URL(string: "http://\(host)/live/\(playCode).m3u8") else { throw PortalError.badURL }
        let headers = [
            "App": AppConfig.apkId,
            "App-Version": AppConfig.apkVersionBody,
            "Content-Auth": authURL,
            "Content-License": addr.license ?? "",
            "User-Agent": "Ranger/4.9.4-17294ac0",
            "Pragma": "akamai-x-cache-on"
        ]
        let source = StreamSource(url: url, quality: addr.quality ?? "Auto", cdnType: ct,
                                  avFormat: addr.AVFormat, license: addr.license, headers: headers)
        return PlayableStream(title: channel.displayName, sources: [source], isLive: true,
                              channel: channel, columnId: columnId)
    }
}
