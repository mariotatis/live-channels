//
//  AddChannelSheet.swift
//  Channels
//
//  Channel picker shown from the player's "+" button, mirroring the Home
//  navigation: a category list (All Channels + the portal's live categories) →
//  push into a searchable channel grid → back, etc. Picking a channel resolves
//  its stream and adds it to the multiview mosaic (PlaybackSession.addChannel).
//
//  Presented as a 3/4-height sheet with the system's translucent (liquid-glass)
//  backing — so no opaque `mooveesBackground` here; the list/grid stay clear.
//

import SwiftUI
import UIKit

struct AddChannelSheet: View {
    let onClose: () -> Void

    var body: some View {
        NavContainer {
            AddChannelCategoryList(onClose: onClose)
        }
        .tint(Theme.accent)   // match the app's accent (alert/back buttons) inside the cover
        .fractionDetentIfAvailable(0.75)
    }
}

// MARK: - Category list (the sheet's root, like Home)

private struct AddChannelCategoryList: View {
    @ObservedObject private var store = LiveStore.shared
    let onClose: () -> Void

    var body: some View {
        List {
            NavigationLink {
                AddChannelGrid(category: nil, onClose: onClose)
            } label: {
                Text("All Channels").foregroundStyle(Theme.textPrimary)
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden, edges: .top)

            ForEach(store.categories) { category in
                NavigationLink {
                    AddChannelGrid(category: category, onClose: onClose)
                } label: {
                    AddChannelCategoryRowLabel(category: category)
                }
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .clearListBackground()
        .navigationTitle("Add Channel")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", action: onClose)
            }
        }
    }
}

/// One category row: name + channel count (loaded lazily, cached by LiveStore).
private struct AddChannelCategoryRowLabel: View {
    let category: LiveColumn
    @ObservedObject private var store = LiveStore.shared
    @State private var count: Int?

    var body: some View {
        HStack {
            Text(category.name).foregroundStyle(Theme.textPrimary)
            Spacer()
            if let count {
                Text("\(count)")
                    .font(.subheadline).foregroundStyle(Theme.textSecondary).monospacedDigit()
            }
        }
        .task {
            if count == nil { count = await store.channels(for: category).count }
        }
    }
}

// MARK: - Channel grid for a category (or All Channels when `category` is nil)

private struct AddChannelGrid: View {
    /// nil = the flat "All Channels" list.
    let category: LiveColumn?
    let onClose: () -> Void

    @ObservedObject private var store = LiveStore.shared
    @State private var channels: [Channel] = []
    @State private var isLoading = true
    @State private var query = ""
    @State private var loadingCode: String?
    @State private var errorMessage: String?
    @State private var lastFailed: Channel?
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    /// Match the Home grid: 6 per row in landscape (compact height) or on iPad,
    /// 3 per row in portrait.
    private var columns: [GridItem] {
        let count: Int
        if UIDevice.current.userInterfaceIdiom == .pad {
            count = 6
        } else {
            count = verticalSizeClass == .compact ? 6 : 3
        }
        return Array(repeating: GridItem(.flexible(), spacing: 10), count: count)
    }

    private var columnId: Int { category?.id ?? AppConfig.liveColumnId }
    private var title: String { category?.name ?? "All Channels" }

    private var filtered: [Channel] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return channels }
        return channels.filter { $0.displayName.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        ScrollView {
            if isLoading {
                LoadingView().frame(maxWidth: .infinity, minHeight: 320)
            } else if filtered.isEmpty {
                EmptyStateView(icon: "tv.slash", title: "No Channels",
                               message: query.isEmpty ? "No channels here."
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
                            onToggleFavorite: { store.toggleFavorite(channel, columnId: columnId) }
                        )
                    }
                }
                .padding()
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Search channels")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", action: onClose)
            }
        }
        .task {
            guard channels.isEmpty else { return }
            channels = category == nil ? store.allChannels : await store.channels(for: category!)
            isLoading = false
        }
        .refreshErrorAlert("Couldn’t Add Channel", message: $errorMessage) {
            Task {
                await LiveStore.shared.refresh()
                if let channel = lastFailed { await add(channel) }
            }
        }
    }

    private func add(_ channel: Channel) async {
        loadingCode = channel.channelCode
        defer { loadingCode = nil }
        do {
            let stream = try await ContentService.shared.liveStream(channel: channel, columnId: columnId)
            PlaybackSession.shared.addChannel(stream)
            onClose()
        } catch {
            lastFailed = channel
            errorMessage = "Couldn’t add \(channel.displayName). Another device may have taken the "
                         + "session — tap Refresh to reclaim it and try again."
        }
    }
}
