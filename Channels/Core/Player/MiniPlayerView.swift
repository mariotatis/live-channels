//
//  MiniPlayerView.swift
//  Channels
//
//  A floating, in-app "mini player" — an app-drawn stand-in for Picture in
//  Picture that works with *any* engine (system PiP is native/AVPlayer only,
//  and most channels play on VLC). The full-screen player shrinks into this
//  window (bottom-right) via PlaybackSession.minimize(); the same coordinator
//  keeps playing, so the video just moves surface. Tap the window to expand
//  back to full screen; tap the X to stop playback entirely.
//
//  Rendered as a root-level overlay by RootTabView so it floats above the whole
//  navigation stack while the user keeps browsing.
//

import SwiftUI

struct MiniPlayerView: View {
    @ObservedObject var coordinator: PlaybackCoordinator

    /// 16:9 window height as a fraction of its width.
    private let ratio: CGFloat = 9.0 / 16.0
    private let corner: CGFloat = 14
    private let margin: CGFloat = 12

    var body: some View {
        GeometryReader { geo in
            let size = windowSize(in: geo.size)
            window
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                )
                .overlay(alignment: .topTrailing) { closeButton }
                .shadow(color: .black.opacity(0.45), radius: 16, x: 0, y: 8)
                .contentShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
                .onTapGesture { PlaybackSession.shared.expand() }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(margin)
        }
    }

    /// The window keeps a 16:9 shape but sizes to the orientation:
    ///  • portrait  → 75% of the available width (tall screen has room),
    ///  • landscape → 50% of the available height, so a 16:9 window doesn't
    ///    stretch across nearly the whole width and cover the screen.
    private func windowSize(in container: CGSize) -> CGSize {
        let isPortrait = container.height >= container.width
        if isPortrait {
            let w = container.width * 0.75
            return CGSize(width: w, height: (w * ratio).rounded())
        } else {
            let h = container.height * 0.50
            return CGSize(width: (h / ratio).rounded(), height: h)
        }
    }

    private var window: some View {
        ZStack {
            Color.black
            // fill: false → fit the stream inside the window (no crop).
            PlaybackVideoSurface(coordinator: coordinator, fill: false)
            if coordinator.isBuffering {
                ProgressView().tint(.white)
            }
        }
    }

    private var closeButton: some View {
        Button { PlaybackSession.shared.endCurrent() } label: {
            Image(systemName: "xmark")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .padding(7)
                .background(.black.opacity(0.55), in: Circle())
        }
        .padding(8)
        .accessibilityLabel("Close mini player")
    }
}
