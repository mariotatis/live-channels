//
//  LiveComponents.swift
//  Channels
//
//  Shared building blocks for the three live-TV tabs: a channel grid and the
//  full-screen-player presentation (cover + error alert).
//

import SwiftUI

/// Grid of channel cards (3 per row) with favorite toggle + tap-to-play.
/// `columnIdFor` supplies the columnId a channel plays from — this matters for
/// category-only channels (e.g. 18+) whose startPlayLive fails under the flat
/// ChannelList column. Defaults to the flat ChannelList column.
struct ChannelGridView: View {
    let channels: [Channel]
    @Bindable var store: LiveStore
    @Bindable var playback: LivePlayback
    var columnIdFor: (Channel) -> Int = { _ in AppConfig.liveColumnId }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

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
    /// Attaches the full-screen player cover and the playback-error alert.
    func livePlayer(_ playback: LivePlayback) -> some View {
        modifier(LivePlayerModifier(playback: playback))
    }
}

private struct LivePlayerModifier: ViewModifier {
    @Bindable var playback: LivePlayback

    func body(content: Content) -> some View {
        content
            .fullScreenCover(item: $playback.playerStream) { stream in
                PlayerView(stream: stream)
            }
            .sheet(item: $playback.pinRequest) { request in
                NavigationStack {
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
