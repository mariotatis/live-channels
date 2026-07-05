//
//  FavoritesView.swift
//  Channels
//
//  "Favorites" tab: the channels the user has favorited (persisted locally in
//  LiveStore). Same grid + tap-to-play as the Channels tab.
//

import SwiftUI

struct FavoritesView: View {
    @ObservedObject private var store = LiveStore.shared
    @StateObject private var playback = LivePlayback()

    var body: some View {
        content
            .navigationTitle("Favorites")
            .navigationBarTitleDisplayMode(.inline)
            .mooveesBackground()
            .task { await store.loadIfNeeded() }
            .livePlayer(playback)
    }

    @ViewBuilder
    private var content: some View {
        if store.isLoading && store.allChannels.isEmpty {
            LoadingView()
        } else if store.favoriteChannels.isEmpty {
            EmptyStateView(icon: "heart",
                           title: "No Favorites Yet",
                           message: "Tap the heart on any channel to add it here.")
        } else {
            ScrollView {
                ChannelGridView(channels: store.favoriteChannels, store: store, playback: playback,
                                columnIdFor: { store.favoriteColumnId(for: $0.channelCode) ?? AppConfig.liveColumnId })
                    .padding(.vertical)
            }
        }
    }
}

#Preview {
    NavContainer { FavoritesView() }
}
