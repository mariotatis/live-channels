//
//  LiveView.swift
//  Channels
//
//  "Channels" tab: the full list of available live channels with a
//  search-by-name field. No category chips, no EPG guide, no channel numbers —
//  tap a channel to play, tap the heart to favorite.
//

import SwiftUI

struct LiveView: View {
    @State private var store = LiveStore.shared
    @State private var playback = LivePlayback()
    @State private var query = ""

    private var filteredChannels: [Channel] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return store.allChannels }
        return store.allChannels.filter { $0.displayName.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Channels")
                .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                            prompt: "Search channels")
                .mooveesBackground()
                .task { await store.loadIfNeeded() }
                .livePlayer(playback)
        }
    }

    @ViewBuilder
    private var content: some View {
        if store.isLoading && store.allChannels.isEmpty {
            LoadingView()
        } else if let errorMessage = store.errorMessage, store.allChannels.isEmpty {
            ErrorView(message: errorMessage) { Task { await store.load() } }
        } else {
            ScrollView {
                if filteredChannels.isEmpty {
                    EmptyStateView(icon: "tv.slash", title: "No Channels",
                                   message: query.isEmpty ? "No channels available yet."
                                                          : "No channels match “\(query)”.")
                    .padding(.top, 80)
                } else {
                    ChannelGridView(channels: filteredChannels, store: store, playback: playback)
                        .padding(.vertical)
                }
            }
            .refreshable { await store.load() }
        }
    }
}

#Preview {
    LiveView()
}
