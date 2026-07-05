//
//  LiveComponents.swift
//  Channels
//
//  Shared building blocks for the three live-TV tabs: a channel grid and the
//  full-screen-player presentation (cover + error alert).
//

import SwiftUI
import UIKit

/// Grid of channel cards (3 per row) with favorite toggle + tap-to-play.
/// `columnIdFor` supplies the columnId a channel plays from — this matters for
/// category-only channels (e.g. 18+) whose startPlayLive fails under the flat
/// ChannelList column. Defaults to the flat ChannelList column.
struct ChannelGridView: View {
    let channels: [Channel]
    @ObservedObject var store: LiveStore
    @ObservedObject var playback: LivePlayback
    var columnIdFor: (Channel) -> Int = { _ in AppConfig.liveColumnId }

    /// iPhone shows 3 per row in portrait and 6 in landscape (vertical size class
    /// `.compact`). iPad is roomy enough for 6 in both orientations — and its
    /// vertical size class is always `.regular`, so it needs an explicit case.
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private var columns: [GridItem] {
        let count: Int
        if UIDevice.current.userInterfaceIdiom == .pad {
            count = 6
        } else {
            count = verticalSizeClass == .compact ? 6 : 3
        }
        return Array(repeating: GridItem(.flexible(), spacing: 10), count: count)
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(channels) { channel in
                LiveChannelCard(
                    channel: channel,
                    isFavorite: store.isFavorite(channel),
                    isSelected: false,
                    isLoading: playback.loadingChannelCode == channel.channelCode,
                    onSelect: { Task { await playback.play(channel, columnId: columnIdFor(channel)) } },
                    onToggleFavorite: { store.toggleFavorite(channel, columnId: columnIdFor(channel)) }
                )
            }
        }
        .padding(.horizontal)
    }
}

extension View {
    /// Attaches the PIN prompt and the playback-error alert. The full-screen
    /// player itself is presented app-wide from PlaybackSession (see RootTabView)
    /// so Picture in Picture can outlive any single tab.
    func livePlayer(_ playback: LivePlayback) -> some View {
        modifier(LivePlayerModifier(playback: playback))
    }
}

private struct LivePlayerModifier: ViewModifier {
    @ObservedObject var playback: LivePlayback

    func body(content: Content) -> some View {
        content
            .sheet(item: $playback.pinRequest) { request in
                NavContainer {
                    PinEntryView(title: request.channel.displayName,
                                 subtitle: "Enter your PIN to play this channel") {
                        playback.pinAccepted()
                    }
                    .navigationTitle("Restricted").navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { playback.pinRequest = nil }
                        }
                    }
                }
            }
            .alert("Playback Error", isPresented: Binding(
                get: { playback.errorMessage != nil },
                set: { if !$0 { playback.errorMessage = nil } }
            )) {
                Button("Refresh") { Task { await playback.refreshAndRetry() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(playback.errorMessage ?? "")
            }
    }
}
