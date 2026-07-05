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
    /// The live playback engines; survives `isPresenting` going false while PiP runs.
    @Published private(set) var coordinator: PlaybackCoordinator?

    private init() {}

    /// Begin playing a resolved stream, replacing any current playback.
    func present(_ stream: PlayableStream) {
        endCurrent()
        let coordinator = PlaybackCoordinator(stream: stream)
        coordinator.onRestoreUI = { [weak self] in self?.isPresenting = true }
        coordinator.onPiPStopped = { [weak self] in
            guard let self else { return }
            // PiP closed by the user. Only end playback if the full player UI
            // isn't on screen (otherwise stopping PiP just returns to inline).
            if !self.isPresenting { self.endCurrent() }
        }
        self.coordinator = coordinator
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

    /// Stop playback and drop the session.
    func endCurrent() {
        coordinator?.teardown()
        coordinator = nil
        isPresenting = false
    }
}
