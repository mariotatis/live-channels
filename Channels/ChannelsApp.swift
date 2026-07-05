//
//  ChannelsApp.swift
//  Channels
//
//  Xuper-family IPTV client, built entirely around Live TV.
//  Entry point → silent activation gate → root tabs (Home / Channels / Favorites).
//

import SwiftUI
import UIKit

@main
struct ChannelsApp: App {
    init() {
        // iOS 16+ hides the List background per-view via `clearListBackground()`
        // (scrollContentBackground). iOS 15 has no such modifier, so make the
        // underlying UITableView transparent globally to reveal mooveesBackground.
        if #unavailable(iOS 16.0) {
            UITableView.appearance().backgroundColor = .clear
            UITableViewCell.appearance().backgroundColor = .clear
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
