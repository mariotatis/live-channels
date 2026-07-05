//
//  Components.swift
//  Channels
//
//  Reusable UI building blocks used across every feature.
//

import SwiftUI

// MARK: - Remote image with placeholder

struct PosterImage: View {
    let url: URL?
    var aspectRatio: CGFloat = 2.0 / 3.0     // portrait poster by default
    var corner: CGFloat = Theme.posterCorner

    var body: some View {
        // A fixed-aspect box (sized by its width); the image fills and is clipped to it.
        Color.clear
            .aspectRatio(aspectRatio, contentMode: .fit)
            .overlay {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .empty:
                        ZStack { Theme.surfaceElevated; ProgressView().tint(Theme.textTertiary) }
                    case .failure:
                        ZStack {
                            Theme.surfaceElevated
                            Image(systemName: "film").font(.title2).foregroundStyle(Theme.textTertiary)
                        }
                    @unknown default:
                        Theme.surfaceElevated
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}

// MARK: - State views

struct LoadingView: View {
    var body: some View {
        ProgressView().tint(Theme.accent)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .mooveesBackground()
    }
}

struct ErrorView: View {
    let message: String
    var retry: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.exclamationmark").font(.largeTitle).foregroundStyle(Theme.textSecondary)
            Text(message).font(.callout).foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center).padding(.horizontal, 40)
            if let retry {
                Button("Try Again", action: retry)
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .mooveesBackground()
    }
}

struct EmptyStateView: View {
    let icon: String
    let title: String
    var message: String? = nil

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.largeTitle).foregroundStyle(Theme.textTertiary)
            Text(title).font(.headline).foregroundStyle(Theme.textSecondary)
            if let message {
                Text(message).font(.subheadline).foregroundStyle(Theme.textTertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
