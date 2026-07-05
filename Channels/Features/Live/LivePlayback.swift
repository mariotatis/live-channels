//
//  LivePlayback.swift
//  Channels
//
//  Small per-view controller that turns a tapped Channel into a full-screen
//  player: resolves the authed CDN stream, tracks which channel is loading,
//  surfaces a playback error, and PIN-gates restricted channels when parental
//  control is on. Used by Home, Channels, and Favorites.
//

import Foundation
import Combine

@MainActor
final class LivePlayback: ObservableObject {
    @Published var loadingChannelCode: String?
    @Published var errorMessage: String?
    @Published var isRefreshing = false

    /// Set when a restricted channel needs the PIN before it can play.
    @Published var pinRequest: PinRequest?

    /// The last channel we tried to play, for a refresh-and-retry.
    private var lastAttempt: (channel: Channel, columnId: Int)?

    struct PinRequest: Identifiable {
        let id = UUID()
        let channel: Channel
        let columnId: Int
    }

    func play(_ channel: Channel, columnId: Int = AppConfig.liveColumnId) async {
        lastAttempt = (channel, columnId)
        if ParentalControl.shared.requiresPin(for: channel) {
            pinRequest = PinRequest(channel: channel, columnId: columnId)
            return
        }
        await start(channel, columnId: columnId)
    }

    /// Called when the PIN prompt for `pinRequest` succeeds.
    func pinAccepted() {
        ParentalControl.shared.grantTemporaryUnlock()
        guard let request = pinRequest else { return }
        pinRequest = nil
        Task { await start(request.channel, columnId: request.columnId) }
    }

    /// Refresh the (possibly stale) catalog, then retry the last channel.
    func refreshAndRetry() async {
        isRefreshing = true
        errorMessage = nil
        await LiveStore.shared.load()
        isRefreshing = false
        if let attempt = lastAttempt {
            await start(attempt.channel, columnId: attempt.columnId)
        }
    }

    private func start(_ channel: Channel, columnId: Int) async {
        loadingChannelCode = channel.channelCode
        errorMessage = nil
        defer { loadingChannelCode = nil }
        do {
            let stream = try await ContentService.shared.liveStream(channel: channel, columnId: columnId)
            PlaybackSession.shared.present(stream)
        } catch {
            errorMessage = "Couldn’t start \(channel.displayName). The channel list may be out of date — tap Refresh to reload it."
        }
    }
}
