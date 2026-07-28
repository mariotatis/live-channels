//
//  AddChannelSheet.swift
//  Channels
//
//  Channel picker shown from the player's "+" button. It renders the same live
//  channel list; tapping a channel resolves its stream and adds it to the
//  multiview mosaic (PlaybackSession.addChannel) as a new tile with audio focus.
//

import SwiftUI

struct AddChannelSheet: View {
    @ObservedObject private var store = LiveStore.shared
    @State private var query = ""
    @State private var loadingCode: String?
    let onClose: () -> Void

    private var filtered: [Channel] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return store.allChannels }
        return store.allChannels.filter { $0.displayName.localizedCaseInsensitiveContains(trimmed) }
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    var body: some View {
        NavContainer {
            ScrollView {
                if filtered.isEmpty {
                    EmptyStateView(icon: "tv.slash", title: "No Channels",
                                   message: query.isEmpty ? "No channels available yet."
                                                          : "No channels match “\(query)”.")
                    .padding(.top, 60)
                } else {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(filtered) { channel in
                            LiveChannelCard(
                                channel: channel,
                                isFavorite: store.isFavorite(channel),
                                isSelected: false,
                                isLoading: loadingCode == channel.channelCode,
                                onSelect: { Task { await add(channel) } },
                                onToggleFavorite: { store.toggleFavorite(channel, columnId: AppConfig.liveColumnId) }
                            )
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("Add Channel")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Search channels")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onClose)
                }
            }
        }
        .fractionDetentIfAvailable(0.75)
    }

    private func add(_ channel: Channel) async {
        loadingCode = channel.channelCode
        defer { loadingCode = nil }
        guard let stream = try? await ContentService.shared.liveStream(channel: channel,
                                                                        columnId: AppConfig.liveColumnId)
        else { return }
        PlaybackSession.shared.addChannel(stream)
        onClose()
    }
}
