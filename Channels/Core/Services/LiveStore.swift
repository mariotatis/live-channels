//
//  LiveStore.swift
//  Channels
//
//  Single source of truth for the live-TV catalog, shared across the Home,
//  Channels, and Favorites tabs:
//   • the full channel list (getLiveData 76182)
//   • the category tree (getColumnContents 76175) + per-category channels
//   • locally-persisted favorites (full channel + its source columnId, so
//     category-only channels like 18+ can be played back correctly)
//
//  Catalog data is cached to disk for 48h: a cold launch loads instantly from
//  cache; pull-to-refresh refetches from the network and rewrites the cache.
//

import Foundation
import Observation

/// A favorited channel plus the columnId it was played from. The columnId
/// matters: some channels (e.g. 18+) only exist under their category column,
/// not the flat ChannelList, and startPlayLive needs the right one.
struct FavoriteChannel: Codable, Identifiable, Hashable {
    var channel: Channel
    var columnId: Int
    var id: String { channel.channelCode }
}

@MainActor
@Observable
final class LiveStore {
    static let shared = LiveStore()

    // MARK: Catalog
    var allChannels: [Channel] = []
    var categories: [LiveColumn] = []
    private(set) var categoryChannels: [Int: [Channel]] = [:]

    var isLoading = false
    var errorMessage: String?

    // MARK: Favorites (local only)
    private(set) var favorites: [FavoriteChannel] = []
    private var favoriteCodes: Set<String> = []

    private let defaults = UserDefaults.standard
    private let favKey = "live.favorites.v2"

    // MARK: Cache
    private let cacheTTL: TimeInterval = 48 * 60 * 60   // 48 hours
    private var cacheTimestamp: Date?

    private var cacheURL: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("live_catalog_cache.json")
    }

    private init() {
        if let data = defaults.data(forKey: favKey),
           let decoded = try? JSONDecoder().decode([FavoriteChannel].self, from: data) {
            favorites = decoded
        }
        favoriteCodes = Set(favorites.map(\.id))
    }

    // MARK: - Loading

    /// Used on first appearance: serve from a fresh disk cache if present,
    /// otherwise fetch from the network.
    func loadIfNeeded() async {
        guard allChannels.isEmpty, !isLoading else { return }
        if loadFromCache() { return }
        await load()
    }

    /// Fetch the catalog from the network and rewrite the cache. Also used by
    /// pull-to-refresh (which discards any cached data by fetching anew).
    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            // Sequential (not concurrent): the account allows one active device
            // session at a time, so back-to-back calls are more reliable.
            let channels = try await ContentService.shared.liveChannels()
            guard !channels.isEmpty else {
                errorMessage = "Couldn’t load channels. Pull to refresh to try again."
                return
            }
            allChannels = channels
            categories = (try? await ContentService.shared.liveCategories()) ?? []
            categoryChannels = [:]           // fresh — per-category lists reload lazily
            cacheTimestamp = Date()
            saveCache()                      // only cache a non-empty catalog
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Channels for a given category column, loaded lazily and cached (memory +
    /// disk, so counts and lists survive an app relaunch within the TTL).
    func channels(for category: LiveColumn) async -> [Channel] {
        if let cached = categoryChannels[category.id] { return cached }
        let list = (try? await ContentService.shared.liveChannels(columnId: category.id)) ?? []
        guard !list.isEmpty else { return list }   // don't cache a transient empty result
        categoryChannels[category.id] = list
        saveCache()
        return list
    }

    // MARK: - Disk cache

    private struct CatalogCache: Codable {
        var timestamp: Date
        var allChannels: [Channel]
        var categories: [LiveColumn]
        var categoryChannels: [Int: [Channel]]
    }

    /// Loads catalog state from disk if the cache exists and is < 48h old.
    @discardableResult
    private func loadFromCache() -> Bool {
        guard let data = try? Data(contentsOf: cacheURL),
              let cache = try? JSONDecoder().decode(CatalogCache.self, from: data),
              !cache.allChannels.isEmpty,
              Date().timeIntervalSince(cache.timestamp) < cacheTTL else {
            return false
        }
        allChannels = cache.allChannels
        categories = cache.categories
        categoryChannels = cache.categoryChannels
        cacheTimestamp = cache.timestamp
        return true
    }

    private func saveCache() {
        let cache = CatalogCache(timestamp: cacheTimestamp ?? Date(),
                                 allChannels: allChannels,
                                 categories: categories,
                                 categoryChannels: categoryChannels)
        if let data = try? JSONEncoder().encode(cache) {
            try? data.write(to: cacheURL, options: .atomic)
        }
    }

    // MARK: - Favorites

    func isFavorite(code: String) -> Bool { favoriteCodes.contains(code) }
    func isFavorite(_ channel: Channel) -> Bool { isFavorite(code: channel.channelCode) }

    /// Toggle a channel's favorite state, remembering the columnId it plays from.
    func toggleFavorite(_ channel: Channel, columnId: Int) {
        if let idx = favorites.firstIndex(where: { $0.id == channel.channelCode }) {
            favorites.remove(at: idx)
        } else {
            favorites.insert(FavoriteChannel(channel: channel, columnId: columnId), at: 0)
        }
        favoriteCodes = Set(favorites.map(\.id))
        persistFavorites()
    }

    /// The columnId a favorited channel should be played from (nil if not saved).
    func favoriteColumnId(for code: String) -> Int? {
        favorites.first { $0.id == code }?.columnId
    }

    /// Favorite channels, most-recently-added first.
    var favoriteChannels: [Channel] { favorites.map(\.channel) }

    private func persistFavorites() {
        if let data = try? JSONEncoder().encode(favorites) { defaults.set(data, forKey: favKey) }
    }
}
