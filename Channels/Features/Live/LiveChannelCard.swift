//
//  LiveChannelCard.swift
//  Channels
//
//  Single channel cell for the Live browser grid: logo, name, favorite toggle,
//  and a small restricted/lock badge (info only — no parental wall per spec).
//  Channel number and quality tag are intentionally hidden.
//

import SwiftUI

struct LiveChannelCard: View {
    let channel: Channel
    let isFavorite: Bool
    let isSelected: Bool
    let isLoading: Bool
    let onSelect: () -> Void
    let onToggleFavorite: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .topTrailing) {
                    PosterImage(url: channel.logoURL, aspectRatio: 16.0 / 9.0, corner: Theme.posterCorner)

                    if isLoading {
                        ZStack {
                            Color.black.opacity(0.45)
                            ProgressView().tint(.white)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: Theme.posterCorner, style: .continuous))
                    }

                    Button(action: onToggleFavorite) {
                        Image(systemName: isFavorite ? "heart.fill" : "heart")
                            .font(.subheadline)
                            .foregroundStyle(isFavorite ? AnyShapeStyle(Theme.brandGradient) : AnyShapeStyle(.white))
                            .padding(8)
                            .background(.black.opacity(0.5), in: Circle())
                    }
                    .padding(2)
                    .buttonStyle(.plain)
                }

                HStack(spacing: 6) {
                    Text(channel.displayName)
                        .font(.caption).fontWeight(.medium)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let restricted = channel.restricted, restricted != "0", !restricted.isEmpty {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
            }
            .padding(8)
            .background(isSelected ? Theme.surfaceElevated : Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.posterCorner + 4, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.posterCorner + 4, style: .continuous)
                    .strokeBorder(isSelected ? Theme.accent : .clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }
}
