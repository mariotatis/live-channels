//
//  PlaybackSession.swift
//  Channels
//
//  App-scoped owner of the current playback. The player screen is presented at
//  the root (see RootTabView) from here rather than per-tab, so that:
//   • Picture in Picture keeps floating after the full-screen player is closed —
//     the coordinator (and its AVPlayer + PiP controller) outlive the view.
//   • The PiP "restore" button can re-present the player from any tab.
//
//  Multiview: the player can show up to `maxTiles` channels at once (a mosaic).
//  Each tile is its own `PlaybackCoordinator`; exactly one tile is the audio
//  focus (`activeIndex`) — the others are muted. `activeIndex` is also the tile
//  the shared top-bar controls (title, favorite, subtitles, fill, engine) act
//  on, and the only one kept when the player is minimized.
//
//  A channel starts playback via LivePlayback → `present(_:)`. Additional
//  channels are added with `addChannel(_:)` from the "+" sheet in the player.
//

import Foundation
import Combine

@MainActor
final class PlaybackSession: ObservableObject {
    static let shared = PlaybackSession()

    /// Max simultaneous channels in the multiview mosaic.
    static let maxTiles = 4

    /// Drives the root-level full-screen player cover.
    @Published var isPresenting = false
    /// Drives the floating in-app mini player (see MiniPlayerView). The same
    /// coordinator keeps playing; only the surface it draws into changes.
    @Published var isMinimized = false
    /// The playing tiles (1…maxTiles); survives `isPresenting` going false while
    /// a PiP or mini-player session runs.
    @Published private(set) var tiles: [PlaybackCoordinator] = []
    /// Which tile owns audio focus and drives the shared controls.
    @Published var activeIndex = 0

    private init() {}

    /// The audio-focused / control-driving coordinator (nil if nothing playing).
    var coordinator: PlaybackCoordinator? {
        guard !tiles.isEmpty else { return nil }
        return tiles[min(activeIndex, tiles.count - 1)]
    }

    /// Whether another channel can be added to the mosaic.
    var canAddMore: Bool { !tiles.isEmpty && tiles.count < Self.maxTiles }

    /// Begin playing a resolved stream, replacing any current playback.
    ///
    /// If the mini player is currently up, the new channel takes over the mini
    /// player (stays minimized) so tapping channels while browsing swaps what's
    /// playing without yanking the user to full screen — they expand to the
    /// details page by tapping the mini player itself. With no mini player up,
    /// a tapped channel opens full screen as before.
    func present(_ stream: PlayableStream) {
        // Selecting a channel while the mini player is up swaps only the focused
        // tile in place, keeping the rest of the mosaic intact — so expanding
        // restores the full grid with just the focused channel changed.
        if isMinimized, !tiles.isEmpty {
            replaceActiveTile(with: stream)
            return
        }
        endCurrent()
        // VLC is the default engine everywhere — opening a channel plays on VLC
        // (broadest codec support). The user can switch to the native player from
        // the settings gear if they want AirPlay / Picture in Picture.
        let coordinator = makeCoordinator(for: stream, startOn: .vlc)
        coordinator.setMuted(false)
        tiles = [coordinator]
        activeIndex = 0
        isMinimized = false
        isPresenting = true
    }

    /// Swap the focused tile's channel in place, leaving the other mosaic tiles
    /// untouched (used when picking a channel while minimized).
    private func replaceActiveTile(with stream: PlayableStream) {
        let idx = min(activeIndex, tiles.count - 1)
        let coordinator = makeCoordinator(for: stream, startOn: .vlc)
        tiles[idx].teardown()
        tiles[idx] = coordinator
        activeIndex = idx
        applyAudioFocus()
    }

    /// Add another channel to the mosaic (up to `maxTiles`). The new tile becomes
    /// the audio focus; the others are muted.
    ///
    /// Existing tiles are left completely untouched — switching their engine here
    /// re-initialised the player and left the previous channel black, so each tile
    /// keeps whatever engine it resolved to (native, or VLC if it fell back).
    func addChannel(_ stream: PlayableStream) {
        guard canAddMore else { return }
        let coordinator = makeCoordinator(for: stream, startOn: .vlc)
        tiles.append(coordinator)
        activeIndex = tiles.count - 1                      // newest owns audio
        applyAudioFocus()
    }

    /// Remove the tile at `index`. Removing down to one tile leaves a normal
    /// single-channel player.
    func removeTile(at index: Int) {
        guard tiles.indices.contains(index) else { return }
        let removed = tiles.remove(at: index)
        removed.teardown()
        if tiles.isEmpty { endCurrent(); return }
        activeIndex = min(activeIndex, tiles.count - 1)
        applyAudioFocus()
    }

    /// Focus a tile for audio (mutes the rest) and route the shared controls to it.
    func setActive(_ index: Int) {
        guard tiles.indices.contains(index) else { return }
        activeIndex = index
        applyAudioFocus()
    }

    /// Shrink the player into the floating mini player, leaving the stream
    /// playing while the user keeps navigating the app. A multiview collapses to
    /// just the focused channel (the mini plays only the one with audio).
    func minimize() {
        guard let active = coordinator else { return }
        // Keep the whole mosaic alive — the mini player only *shows* the focused
        // channel, but the other tiles keep playing (muted) so expanding restores
        // the full grid with any swap applied.
        active.select(.vlc)          // the mini player runs on VLC
        active.setMuted(false)
        isPresenting = false
        isMinimized = true
    }

    /// Bring the mini player (or a restored PiP session) back to full screen.
    func expand() {
        guard !tiles.isEmpty else { return }
        isMinimized = false
        isPresenting = true
    }

    /// The user closed the full-screen player. Keep the session alive for a
    /// floating PiP window if PiP is active; otherwise stop playback entirely.
    func dismiss() {
        isPresenting = false
        if coordinator?.isPiPActive != true {
            endCurrent()
        }
    }

    /// Stop all playback and drop the session (full-screen, mini and mosaic).
    func endCurrent() {
        tiles.forEach { $0.teardown() }
        tiles = []
        activeIndex = 0
        isPresenting = false
        isMinimized = false
    }

    // MARK: - Helpers

    private func makeCoordinator(for stream: PlayableStream,
                                 startOn engine: PlayerEngine) -> PlaybackCoordinator {
        let coordinator = PlaybackCoordinator(stream: stream, startOn: engine)
        coordinator.onRestoreUI = { [weak self] in self?.expand() }
        coordinator.onPiPStopped = { [weak self] in
            guard let self else { return }
            // PiP closed by the user. Only end playback if neither the full
            // player nor the mini player is on screen (otherwise stopping PiP
            // just returns to whichever inline surface is showing).
            if !self.isPresenting && !self.isMinimized { self.endCurrent() }
        }
        return coordinator
    }

    /// Unmute the focused tile, mute the rest.
    private func applyAudioFocus() {
        for (i, tile) in tiles.enumerated() { tile.setMuted(i != activeIndex) }
    }
}
