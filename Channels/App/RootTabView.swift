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
                    PlayerView(coordinator: coordinator)
                }
            }
    }
}
