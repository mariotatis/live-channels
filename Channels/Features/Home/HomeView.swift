//
//  HomeView.swift
//  Channels
//
//  "Categories" tab: a plain list of the portal's live category names
//  (Deportes, Cine y Series, countries, Noticias, NFL/NBA PASS, Música…).
//  Tapping a category pushes a searchable channel grid for that category.
//

import SwiftUI

struct HomeView: View {
    @State private var store = LiveStore.shared
    @State private var showParental = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Categories")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showParental = true } label: {
                            Image(systemName: "lock.shield")
                                .foregroundStyle(Theme.brandGradient)
                        }
                    }
                }
                .mooveesBackground()
                .task { await store.loadIfNeeded() }
                .navigationDestination(for: LiveColumn.self) { category in
                    CategoryChannelsView(category: category)
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
        } else if store.categories.isEmpty {
            EmptyStateView(icon: "square.grid.2x2",
                           title: "No Categories",
                           message: "Live categories aren’t available right now.")
        } else {
            List(store.categories) { category in
                CategoryRow(category: category, store: store)
                    .listRowBackground(Theme.surface)
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
