//
//  RootTabView.swift
//  Channels
//
//  Root shell (no tab bar): a single "Live Channels" navigation stack. From it
//  the user reaches All Channels, each category, and their liked channels. The
//  full-screen player is presented app-wide from PlaybackSession so a PiP session
//  survives navigation.
//

import SwiftUI

struct RootTabView: View {
    @StateObject private var playbackSession = PlaybackSession.shared

    var body: some View {
        HomeView()
            .tint(Theme.accent)
            .fullScreenCover(isPresented: $playbackSession.isPresenting) {
                if let coordinator = playbackSession.coordinator {
                    // .id ties the view to the coordinator: swapping to a new
                    // channel (new coordinator) rebuilds the video surface
                    // instead of reusing the torn-down one (which shows black).
                    PlayerView(coordinator: coordinator)
                        .id(ObjectIdentifier(coordinator))
                }
            }
            // Floating mini player: shown when the full-screen player has been
            // minimized (and system PiP isn't already floating the video).
            .overlay(alignment: .bottomTrailing) {
                if playbackSession.isMinimized,
                   let coordinator = playbackSession.coordinator,
                   !coordinator.isPiPActive {
                    MiniPlayerView(coordinator: coordinator)
                        .id(ObjectIdentifier(coordinator))
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.85),
                       value: playbackSession.isMinimized)
    }
}
