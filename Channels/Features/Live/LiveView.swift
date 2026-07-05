//
//  LiveView.swift
//  Channels
//
//  "Channels" tab: the full list of available live channels with a
//  search-by-name field. No category chips, no EPG guide, no channel numbers —
//  tap a channel to play, tap the heart to favorite.
//
//  Search adapts to the OS: on iOS 26 it's the floating, minimized bottom-bar
//  search button; on older systems it's a magnifyingglass button in the nav
//  bar's top-right that reveals an inline search field (LegacyChannelSearchBar).
//

import SwiftUI

struct LiveView: View {
    @ObservedObject private var store = LiveStore.shared
    @StateObject private var playback = LivePlayback()
    @State private var query = ""
    /// Safari-style: the title bar hides when scrolling down and reappears scrolling up (iOS 26).
    @State private var chromeHidden = false
    /// Tracks whether the search field is expanded/active.
    @State private var searchPresented = false

    private var filteredChannels: [Channel] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return store.allChannels }
        return store.allChannels.filter { $0.displayName.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        Group {
            if #available(iOS 26.0, *) {
                modernBody
            } else {
                legacyBody
            }
        }
    }

    // MARK: - iOS 26: floating minimized search + Safari-style chrome hide

    @available(iOS 26.0, *)
    private var modernBody: some View {
        channelList(trackScroll: true)
            .navigationTitle("All Channels")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, isPresented: $searchPresented, prompt: "Search channels")
            .searchToolbarBehavior(.minimize)
            .toolbar {
                ToolbarSpacer(.flexible, placement: .bottomBar)
                DefaultToolbarItem(kind: .search, placement: .bottomBar)
            }
            .toolbarVisibility((chromeHidden && !searchPresented) ? .hidden : .visible, for: .navigationBar)
            .animation(.easeInOut(duration: 0.25), value: chromeHidden)
            .mooveesBackground()
            .task { await store.loadIfNeeded() }
            .livePlayer(playback)
    }

    // MARK: - iOS 15–18: top-right search button reveals an inline field

    private var legacyBody: some View {
        VStack(spacing: 0) {
            if searchPresented {
                LegacyChannelSearchBar(query: $query) { closeSearch() }
            }
            channelList(trackScroll: false)
        }
        .navigationTitle("All Channels")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    if searchPresented { closeSearch() }
                    else { withAnimation { searchPresented = true } }
                } label: {
                    Image(systemName: searchPresented ? "xmark" : "magnifyingglass")
                        .foregroundStyle(.white)
                }
                .accessibilityLabel(searchPresented ? "Close Search" : "Search Channels")
            }
        }
        .mooveesBackground()
        .task { await store.loadIfNeeded() }
        .livePlayer(playback)
    }

    private func closeSearch() {
        withAnimation { searchPresented = false }
        query = ""
    }

    /// Update chrome visibility from a scroll offset change (iOS 26 only). Always
    /// shows at the top and while a search is active; otherwise hides going down.
    private func updateChrome(from oldY: CGFloat, to newY: CGFloat) {
        if newY <= 0 || !query.isEmpty || searchPresented {
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
    private func channelList(trackScroll: Bool) -> some View {
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
            .trackScrollChrome(trackScroll ? { old, new in updateChrome(from: old, to: new) } : { _, _ in })
            .refreshable { await store.load() }
        }
    }
}

#Preview {
    NavContainer { LiveView() }
}
