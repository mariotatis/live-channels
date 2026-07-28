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
//  Catalog data lives in memory for the lifetime of the app process: it is
//  fetched once on first appearance and kept as-is across navigation. A fresh
//  process (app killed & relaunched, or reclaimed by the system) reloads from
//  the network. Pull-to-refresh refetches on demand.
//

import Foundation
import Combine

/// A favorited channel plus the columnId it was played from. The columnId
/// matters: some channels (e.g. 18+) only exist under their category column,
/// not the flat ChannelList, and startPlayLive needs the right one.
struct FavoriteChannel: Codable, Identifiable, Hashable {
    var channel: Channel
    var columnId: Int
    var id: String { channel.channelCode }
}

@MainActor
final class LiveStore: ObservableObject {
    static let shared = LiveStore()

    // MARK: Catalog
    @Published var allChannels: [Channel] = []
    @Published var categories: [LiveColumn] = []
    @Published private(set) var categoryChannels: [Int: [Channel]] = [:]

    @Published var isLoading = false
    @Published var errorMessage: String?

    // MARK: Favorites (local only)
    @Published private(set) var favorites: [FavoriteChannel] = []
    private var favoriteCodes: Set<String> = []

    private let defaults = UserDefaults.standard
    private let favKey = "live.favorites.v2"

    private init() {
        if let data = defaults.data(forKey: favKey),
           let decoded = try? JSONDecoder().decode([FavoriteChannel].self, from: data) {
            favorites = decoded
        }
        favoriteCodes = Set(favorites.map(\.id))
    }

    // MARK: - Loading

    /// Used on first appearance: fetch from the network once. Once the catalog
    /// is in memory this is a no-op, so returning from a category doesn't reload.
    func loadIfNeeded() async {
        guard allChannels.isEmpty, !isLoading else { return }
        await load()
    }

    /// How many times a failed/empty catalog fetch is silently retried before
    /// the error is surfaced, and how long to wait between attempts.
    private static let autoRetries = 1
    private static let autoRetryDelay: UInt64 = 2_000_000_000   // 2s in nanoseconds

    /// Fetch the catalog from the network. Also used by pull-to-refresh.
    ///
    /// An empty body or a thrown error on first attempt is almost always the
    /// single-active-device transient (the shared `sn` session is briefly held
    /// elsewhere) — it clears on a retry. So we retry silently after a short
    /// wait, keeping the spinner up, and only surface the error if the retry
    /// also fails. This masks the flicker of an error the user would otherwise
    /// just have to tap "Try Again" to clear.
    func load() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        for attempt in 0...Self.autoRetries {
            let isLastAttempt = attempt == Self.autoRetries
            do {
                // Sequential (not concurrent): the account allows one active
                // device session at a time, so back-to-back calls are more reliable.
                let channels = try await ContentService.shared.liveChannels()
                guard !channels.isEmpty else {
                    if isLastAttempt {
                        errorMessage = "Couldn’t load channels. Pull to refresh to try again."
                        return
                    }
                    try? await Task.sleep(nanoseconds: Self.autoRetryDelay)
                    continue
                }
                allChannels = channels
                categories = (try? await ContentService.shared.liveCategories()) ?? []
                categoryChannels = [:]        // fresh — per-category lists reload lazily
                return
            } catch {
                if isLastAttempt {
                    errorMessage = error.localizedDescription
                    return
                }
                try? await Task.sleep(nanoseconds: Self.autoRetryDelay)
            }
        }
    }

    /// Channels for a given category column, loaded lazily and kept in memory
    /// for the process lifetime (so revisiting a category doesn't refetch).
    func channels(for category: LiveColumn) async -> [Channel] {
        if let cached = categoryChannels[category.id] { return cached }
        let list = (try? await ContentService.shared.liveChannels(columnId: category.id)) ?? []
        guard !list.isEmpty else { return list }   // don't retain a transient empty result
        categoryChannels[category.id] = list
        return list
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
