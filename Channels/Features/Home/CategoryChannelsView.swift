//
//  CategoryChannelsView.swift
//  Channels
//
//  Channels within a single live category, shown as a searchable grid — the
//  same experience as the Channels tab, scoped to one category. The 18+
//  category is PIN-gated when parental control is on.
//
//  Search adapts to the OS (see LiveView): floating minimized bottom-bar search
//  on iOS 26; a nav-bar top-right button revealing an inline field on older iOS.
//

import SwiftUI

struct CategoryChannelsView: View {
    let category: LiveColumn

    @ObservedObject private var store = LiveStore.shared
    @ObservedObject private var parental = ParentalControl.shared
    @StateObject private var playback = LivePlayback()
    @State private var channels: [Channel] = []
    @State private var isLoading = true
    @State private var query = ""
    /// Safari-style: title bar hides scrolling down, reappears scrolling up (iOS 26).
    @State private var chromeHidden = false
    /// Tracks whether the search field is expanded/active.
    @State private var searchPresented = false

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
            if #available(iOS 26.0, *) {
                modernBody
            } else {
                legacyBody
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

    // MARK: - iOS 26: floating minimized search + Safari-style chrome hide

    @available(iOS 26.0, *)
    private var modernBody: some View {
        Group {
            if locked {
                lockedView
            } else {
                gridScroll(trackScroll: true)
                    .searchable(text: $query, isPresented: $searchPresented, prompt: "Search channels")
                    .searchToolbarBehavior(.minimize)
            }
        }
        .toolbar {
            if !locked {
                ToolbarSpacer(.flexible, placement: .bottomBar)
                DefaultToolbarItem(kind: .search, placement: .bottomBar)
            }
        }
        .toolbarVisibility((chromeHidden && !searchPresented) ? .hidden : .visible, for: .navigationBar)
        .animation(.easeInOut(duration: 0.25), value: chromeHidden)
    }

    // MARK: - iOS 15–18: top-right search button reveals an inline field

    private var legacyBody: some View {
        Group {
            if locked {
                lockedView
            } else {
                VStack(spacing: 0) {
                    if searchPresented {
                        LegacyChannelSearchBar(query: $query) { closeSearch() }
                    }
                    gridScroll(trackScroll: false)
                }
            }
        }
        .toolbar {
            // The `if` lives inside the ToolbarItem's (regular) view builder, not
            // the ToolbarContentBuilder — optional ToolbarContent is iOS 16+.
            ToolbarItem(placement: .navigationBarTrailing) {
                if !locked {
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
        }
    }

    private var lockedView: some View {
        PinEntryView(title: category.name,
                     subtitle: "Enter your PIN to view this category") {
            parental.grantTemporaryUnlock()
        }
    }

    private func closeSearch() {
        withAnimation { searchPresented = false }
        query = ""
    }

    // A ScrollView is always present (even while loading) so the search bar has a
    // stable scroll context from the first frame — otherwise its background flashes
    // in when the grid replaces a non-scrolling loading spinner.
    private func gridScroll(trackScroll: Bool) -> some View {
        ScrollView {
            if isLoading {
                LoadingView()
                    .frame(maxWidth: .infinity, minHeight: 320)
            } else if filteredChannels.isEmpty {
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
        .trackScrollChrome(trackScroll ? { old, new in updateChrome(from: old, to: new) } : { _, _ in })
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
}
