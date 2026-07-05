//
//  Compat.swift
//  Channels
//
//  Backwards-compatibility shims so the app runs on iOS 15.6 (e.g. iPhone 8)
//  while keeping the iOS 26 experience byte-for-byte intact on current devices.
//  Everything here is gated by `if #available`; the modern path is unchanged.
//

import SwiftUI

/// A navigation container: `NavigationStack` on iOS 16+, `NavigationView` (stack
/// style) on iOS 15. Value-based `.navigationDestination` is iOS 16+, so screens
/// that rely on it push via `NavigationLink(destination:)` on iOS 15 instead.
struct NavContainer<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(iOS 16.0, *) {
            NavigationStack(root: content)
        } else {
            NavigationView(content: content)
                .navigationViewStyle(.stack)
        }
    }
}

extension View {
    /// Hides the default List/scroll background (iOS 16+). On iOS 15 the List is
    /// made transparent globally via `UITableView` appearance (see `ChannelsApp`),
    /// so this is a no-op there.
    @ViewBuilder
    func clearListBackground() -> some View {
        if #available(iOS 16.0, *) {
            self.scrollContentBackground(.hidden)
        } else {
            self
        }
    }

    /// Constrains a sheet to a medium detent on iOS 16+; full-height on iOS 15.
    @ViewBuilder
    func mediumDetentIfAvailable() -> some View {
        if #available(iOS 16.0, *) {
            self.presentationDetents([.medium])
        } else {
            self
        }
    }

    /// Safari-style chrome hiding driven by scroll offset. Available iOS 18+
    /// (`onScrollGeometryChange`); a no-op on older systems, where the navigation
    /// bar simply stays visible.
    @ViewBuilder
    func trackScrollChrome(_ action: @escaping (CGFloat, CGFloat) -> Void) -> some View {
        if #available(iOS 18.0, *) {
            self.onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { old, new in
                action(old, new)
            }
        } else {
            self
        }
    }
}

/// Inline search field shown at the top of a channel list on iOS < 26, where the
/// floating minimized search button (`searchToolbarBehavior(.minimize)`) doesn't
/// exist. Revealed by a magnifyingglass button in the navigation bar's top-right.
struct LegacyChannelSearchBar: View {
    @Binding var query: String
    var onCancel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Theme.textTertiary)
                TextField("Search channels", text: $query)
                    .focused($focused)
                    .foregroundStyle(Theme.textPrimary)
                    .tint(Theme.accent)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(9)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            Button("Cancel", action: onCancel)
                .foregroundStyle(Theme.accent)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .onAppear { focused = true }
    }
}
