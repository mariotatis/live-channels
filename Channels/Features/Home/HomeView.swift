//
//  HomeView.swift
//  Channels
//
//  "Live Channels" home: an "All Channels" shortcut on top, then the portal's
//  live category names (Deportes, Cine y Series, countries, Noticias, NFL/NBA
//  PASS, Música…). Tapping a category pushes a searchable channel grid; the
//  toolbar has quick access to liked channels and parental control.
//

import SwiftUI

struct HomeView: View {
    @State private var store = LiveStore.shared
    @State private var showParental = false
    @State private var showFavorites = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Live Channels")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showFavorites = true } label: {
                            Image(systemName: "heart")
                                .foregroundStyle(.white)
                        }
                        .accessibilityLabel("Liked Channels")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showParental = true } label: {
                            Image(systemName: "lock.shield")
                                .foregroundStyle(.white)
                        }
                        .accessibilityLabel("Parental Control")
                    }
                }
                .mooveesBackground()
                .task { await store.loadIfNeeded() }
                .navigationDestination(for: LiveColumn.self) { category in
                    CategoryChannelsView(category: category)
                }
                .navigationDestination(isPresented: $showFavorites) {
                    FavoritesView()
                }
                .sheet(isPresented: $showParental) {
                    NavigationStack { ParentalControlView() }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        if store.isLoading && store.categories.isEmpty {
            LoadingView()
        } else if let errorMessage = store.errorMessage, store.categories.isEmpty {
            ErrorView(message: errorMessage) { Task { await store.load() } }
        } else {
            List {
                NavigationLink {
                    LiveView()
                } label: {
                    Text("All Channels")
                        .foregroundStyle(Theme.textPrimary)
                }
                .listRowBackground(Theme.surface)
                .listRowSeparator(.hidden, edges: .top)

                ForEach(store.categories) { category in
                    CategoryRow(category: category, store: store)
                        .listRowBackground(Theme.surface)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .refreshable { await store.load() }
        }
    }
}

/// One category row: name + channel count (loaded lazily as the row appears,
/// which also caches the channels so opening the category is instant).
private struct CategoryRow: View {
    let category: LiveColumn
    let store: LiveStore
    @State private var count: Int?

    var body: some View {
        NavigationLink(value: category) {
            HStack {
                Text(category.name)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                if let count {
                    Text("\(count)")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .monospacedDigit()
                }
            }
        }
        .task {
            if count == nil { count = await store.channels(for: category).count }
        }
    }
}

#Preview {
    HomeView()
}
