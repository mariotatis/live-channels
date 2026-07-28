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
//  A channel starts playback via LivePlayback → `present(_:)`. Closing the player
//  calls `dismiss()`, which keeps the session alive if PiP is active and tears it
//  down otherwise.
//

import Foundation
import Combine

@MainActor
final class PlaybackSession: ObservableObject {
    static let shared = PlaybackSession()

    /// Drives the root-level full-screen player cover.
    @Published var isPresenting = false
    /// Drives the floating in-app mini player (see MiniPlayerView). The same
    /// coordinator keeps playing; only the surface it draws into changes.
    @Published var isMinimized = false
    /// The live playback engines; survives `isPresenting` going false while a
    /// PiP or mini-player session runs.
    @Published private(set) var coordinator: PlaybackCoordinator?

    private init() {}

    /// Begin playing a resolved stream, replacing any current playback.
    ///
    /// If the mini player is currently up, the new channel takes over the mini
    /// player (stays minimized) so tapping channels while browsing swaps what's
    /// playing without yanking the user to full screen — they expand to the
    /// details page by tapping the mini player itself. With no mini player up,
    /// a tapped channel opens full screen as before.
    func present(_ stream: PlayableStream) {
        let keepMinimized = isMinimized && coordinator != nil
        endCurrent()
        // The mini player always runs on VLC (consistent, and PiP/AirPlay don't
        // apply in the floating window), so a channel swapped in while minimized
        // starts straight on VLC.
        let coordinator = PlaybackCoordinator(stream: stream, startOn: keepMinimized ? .vlc : .native)
        coordinator.onRestoreUI = { [weak self] in self?.expand() }
        coordinator.onPiPStopped = { [weak self] in
            guard let self else { return }
            // PiP closed by the user. Only end playback if neither the full
            // player nor the mini player is on screen (otherwise stopping PiP
            // just returns to whichever inline surface is showing).
            if !self.isPresenting && !self.isMinimized { self.endCurrent() }
        }
        self.coordinator = coordinator
        isMinimized = keepMinimized
        isPresenting = !keepMinimized
    }

    /// Shrink the full-screen player into the floating mini player, leaving the
    /// stream playing while the user keeps navigating the app.
    func minimize() {
        guard let coordinator else { return }
        // The mini player always runs on VLC — switch now if we were on native.
        coordinator.select(.vlc)
        isPresenting = false
        isMinimized = true
    }

    /// Bring the mini player (or a restored PiP session) back to full screen.
    func expand() {
        guard coordinator != nil else { return }
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

    /// Stop playback and drop the session (both full-screen and mini player).
    func endCurrent() {
        coordinator?.teardown()
        coordinator = nil
        isPresenting = false
        isMinimized = false
    }
}
