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
    @ObservedObject private var store = LiveStore.shared
    @State private var showParental = false
    @State private var showFavorites = false

    var body: some View {
        NavContainer {
            content
                .navigationTitle("Live Channels")
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button { showFavorites = true } label: {
                            Image(systemName: "heart")
                                .foregroundStyle(.white)
                        }
                        .accessibilityLabel("Liked Channels")
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button { showParental = true } label: {
                            Image(systemName: "lock.shield")
                                .foregroundStyle(.white)
                        }
                        .accessibilityLabel("Parental Control")
                    }
                }
                .mooveesBackground()
                .task { await store.loadIfNeeded() }
                .homeNavigation(showFavorites: $showFavorites)
                .sheet(isPresented: $showParental) {
                    NavContainer { ParentalControlView() }
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
            .clearListBackground()
            .refreshable { await store.load() }
        }
    }
}

private extension View {
    /// Category push + favorites push. Value-based `.navigationDestination` is
    /// iOS 16+; on iOS 15 favorites pushes through a hidden `NavigationLink`
    /// (and `CategoryRow` uses a destination-based link).
    @ViewBuilder
    func homeNavigation(showFavorites: Binding<Bool>) -> some View {
        if #available(iOS 16.0, *) {
            self
                .navigationDestination(for: LiveColumn.self) { category in
                    CategoryChannelsView(category: category)
                }
                .navigationDestination(isPresented: showFavorites) {
                    FavoritesView()
                }
        } else {
            self.background(
                NavigationLink(isActive: showFavorites) {
                    FavoritesView()
                } label: {
                    EmptyView()
                }
                .hidden()
            )
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
        rowLink
            .task {
                if count == nil { count = await store.channels(for: category).count }
            }
    }

    /// iOS 16+ pushes via value (paired with `navigationDestination(for:)`); iOS
    /// 15 pushes the destination directly since value-based routing isn't available.
    @ViewBuilder
    private var rowLink: some View {
        if #available(iOS 16.0, *) {
            NavigationLink(value: category) { label }
        } else {
            NavigationLink { CategoryChannelsView(category: category) } label: { label }
        }
    }

    private var label: some View {
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
}

#Preview {
    HomeView()
}
