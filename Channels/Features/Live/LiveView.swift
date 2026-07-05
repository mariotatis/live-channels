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
    /// Safari-style: the title + search bar hide when scrolling down the list and
    /// reappear when scrolling back up (or at the top).
    @State private var chromeHidden = false

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
                .toolbarVisibility(chromeHidden ? .hidden : .visible, for: .navigationBar)
                .animation(.easeInOut(duration: 0.25), value: chromeHidden)
                .mooveesBackground()
                .task { await store.loadIfNeeded() }
                .livePlayer(playback)
        }
    }

    /// Update chrome visibility from a scroll offset change. Always shows at the
    /// top and while a search is active; otherwise hides going down, shows going up.
    private func updateChrome(from oldY: CGFloat, to newY: CGFloat) {
        if newY <= 0 || !query.isEmpty {
            if chromeHidden { chromeHidden = false }
            return
        }
        let delta = newY - oldY
        if delta > 8, !chromeHidden {
            chromeHidden = true
        } else if delta < -8, chromeHidden {
            chromeHidden = false
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
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { old, new in
                updateChrome(from: old, to: new)
            }
            .refreshable { await store.load() }
        }
    }
}

#Preview {
    LiveView()
}
