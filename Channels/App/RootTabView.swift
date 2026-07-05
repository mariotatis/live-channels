//
//  RootTabView.swift
//  Channels
//
//  Root tab bar: Home (channels by category), Channels (full searchable list),
//  and Favorites (locally-saved channels). Each tab owns its NavigationStack.
//

import SwiftUI

struct RootTabView: View {
    @State private var selection: String = AppTab.home.rawValue
    @StateObject private var playbackSession = PlaybackSession.shared

    var body: some View {
        TabView(selection: $selection) {
            Tab(AppTab.home.title, systemImage: AppTab.home.icon, value: AppTab.home.rawValue) {
                HomeView()
            }
            Tab(AppTab.channels.title, systemImage: AppTab.channels.icon, value: AppTab.channels.rawValue) {
                LiveView()
            }
            Tab(AppTab.favorites.title, systemImage: AppTab.favorites.icon, value: AppTab.favorites.rawValue) {
                FavoritesView()
            }
        }
        .tint(Theme.accent)
        // Presented app-wide so a PiP session survives tab changes / navigation.
        .fullScreenCover(isPresented: $playbackSession.isPresenting) {
            if let coordinator = playbackSession.coordinator {
                PlayerView(coordinator: coordinator)
            }
        }
    }
}
