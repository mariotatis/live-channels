//
//  Theme.swift
//  Channels
//
//  App-wide colors, gradients, and typography helpers.
//

import SwiftUI

enum Theme {
    // Brand gradient endpoints (match the app icon): red → orange.
    static let gradientStart = Color(red: 0.98, green: 0.24, blue: 0.35)  // red
    static let gradientEnd   = Color(red: 1.0,  green: 0.55, blue: 0.25)  // orange

    /// The single unified accent for everything that can't be a gradient
    /// (tab tint, buttons, spinners, chips…) — the midpoint of the icon gradient.
    static let accent = Color(red: 0.99, green: 0.40, blue: 0.30)
    static let accentSecondary = gradientEnd

    static let background = Color(red: 0.05, green: 0.05, blue: 0.07)
    static let surface = Color(red: 0.11, green: 0.11, blue: 0.14)
    static let surfaceElevated = Color(red: 0.16, green: 0.16, blue: 0.2)
    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.65)
    static let textTertiary = Color.white.opacity(0.4)

    /// Brand gradient used on the icon, splash, favorite heart, subtitle & shield.
    static let brandGradient = LinearGradient(
        colors: [gradientStart, gradientEnd],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    static let posterCorner: CGFloat = 10
}

extension View {
    /// Standard screen background.
    func mooveesBackground() -> some View {
        self.background(Theme.background.ignoresSafeArea())
    }
}
