//
//  CategoryChannelsView.swift
//  Channels
//
//  Channels within a single live category, shown as a searchable grid — the
//  same experience as the Channels tab, scoped to one category. The 18+
//  category is PIN-gated when parental control is on.
//

import SwiftUI

struct CategoryChannelsView: View {
    let category: LiveColumn

    @State private var store = LiveStore.shared
    @State private var parental = ParentalControl.shared
    @State private var playback = LivePlayback()
    @State private var channels: [Channel] = []
    @State private var isLoading = true
    @State private var query = ""

    /// The adult category's listing is hidden behind the PIN (respecting the
    /// shared 1-minute unlock window).
    private var locked: Bool {
        parental.requiresPin(forCategory: category)
    }

    private var filteredChannels: [Channel] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return channels }
        return channels.filter { $0.displayName.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        Group {
            if locked {
                PinEntryView(title: category.name,
                             subtitle: "Enter your PIN to view this category") {
                    parental.grantTemporaryUnlock()
                }
            } else {
                grid
                    .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                                prompt: "Search channels")
            }
        }
        .navigationTitle(category.name)
        .navigationBarTitleDisplayMode(.inline)
        .mooveesBackground()
        .task(id: locked) {
            guard !locked, channels.isEmpty else { return }
            channels = await store.channels(for: category)
            isLoading = false
        }
        .livePlayer(playback)
    }

    @ViewBuilder
    private var grid: some View {
        if isLoading {
            LoadingView()
        } else {
            ScrollView {
                if filteredChannels.isEmpty {
                    EmptyStateView(icon: "tv.slash", title: "No Channels",
                                   message: query.isEmpty ? "No channels in this category."
                                                          : "No channels match “\(query)”.")
                    .padding(.top, 80)
                } else {
                    ChannelGridView(channels: filteredChannels, store: store, playback: playback,
                                    columnIdFor: { _ in category.id })
                        .padding(.vertical)
                }
            }
        }
    }
}
