//
//  Router.swift
//  Channels
//
//  Tab definitions for the live-TV app. Navigation is flat (each tab is a
//  self-contained NavigationStack), so there are no cross-feature push routes.
//

import SwiftUI

/// Tabs in the root tab bar.
enum AppTab: String, CaseIterable, Identifiable {
    case home, channels, favorites
    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Categories"
        case .channels: return "Channels"
        case .favorites: return "Favorites"
        }
    }

    var icon: String {
        switch self {
        case .home: return "list.bullet"
        case .channels: return "tv.fill"
        case .favorites: return "heart.fill"
        }
    }
}
