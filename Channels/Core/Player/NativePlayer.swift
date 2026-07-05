//
//  NativePlayer.swift
//  Channels
//
//  AVPlayer-backed engine used as the DEFAULT for every channel. It plays the
//  same auth-gated HLS playlist as VLC by pointing at LocalStreamProxy
//  (127.0.0.1) — the proxy injects the Content-Auth / Content-License headers,
//  and the media segments are open absolute URLs AVFoundation fetches directly.
//
//  A portion of the lineup streams HEVC-in-MPEG-TS, which AVFoundation cannot
//  decode (audio plays, video stays black). We detect that case — the item
//  reaches playback but `presentationSize` never leaves `.zero` — and report it
//  via `onCannotPlayVideo` so the coordinator can fall back to VLC. When native
//  playback works it supports AirPlay (external playback) and Picture in Picture.
//

import SwiftUI
import AVKit
import AVFoundation
import Combine

@MainActor
final class NativePlayerModel: NSObject, ObservableObject {
    @Published var isBuffering = true
    @Published var isPlaying = true
    @Published var hasSubtitles = false
    @Published var subtitlesOn = false
    @Published var fillScreen = false {
        didSet { playerView.playerLayer.videoGravity = fillScreen ? .resizeAspectFill : .resizeAspect }
    }
    @Published var isPiPActive = false
    @Published var pipSupported = false
    /// True while video is playing on an AirPlay device (screen is black locally).
    @Published var isExternalActive = false
    /// The AirPlay target's name (e.g. "Living Room TV"), when external.
    @Published var externalDeviceName: String?

    let stream: PlayableStream
    let player = AVPlayer()

    /// The rendering surface. Owned by the model (NOT the SwiftUI view) so its
    /// AVPlayerLayer — and the PiP controller bound to it — survive the player
    /// screen being dismissed. That's what lets PiP keep floating while the user
    /// navigates the app.
    let playerView = AVPlayerContainerView()
    private var pipController: AVPictureInPictureController?

    // MARK: Native-capability detection
    /// Fired once real video frames render — AVPlayer can handle this channel.
    var onDidRenderVideo: (() -> Void)?
    /// Fired when AVPlayer can't show video (HEVC-in-TS audio-only, load error,
    /// or no frames within the grace window) — the coordinator switches to VLC.
    var onCannotPlayVideo: (() -> Void)?
    /// Fired when the user taps the PiP "restore" button — re-present the UI.
    var onPiPRestoreUI: (() -> Void)?
    /// Fired when PiP stops for a reason OTHER than restoring (user closed the
    /// PiP window) — the session decides whether to end playback.
    var onPiPStopped: (() -> Void)?
    private var pipWillRestore = false
    private var didResolveDetection = false
    private var graceStarted = false

    private var item: AVPlayerItem?
    private var statusObs: NSKeyValueObservation?
    private var presentationObs: NSKeyValueObservation?
    private var timeControlObs: NSKeyValueObservation?
    private var externalObs: NSKeyValueObservation?
    private var absoluteTimeout: Task<Void, Never>?
    private var legibleGroup: AVMediaSelectionGroup?
    /// Whether the current playlist URL is addressed via the LAN IP (for AirPlay).
    private var currentURLIsLAN = false

    init(stream: PlayableStream) {
        self.stream = stream
        super.init()
        configureAudioSession()
        player.allowsExternalPlayback = true
        player.usesExternalPlaybackWhileExternalScreenIsActive = true
        playerView.backgroundColor = .black
        playerView.isUserInteractionEnabled = false   // taps fall through to SwiftUI controls
        playerView.playerLayer.player = player
        playerView.playerLayer.videoGravity = .resizeAspect
        setupPiP()

        // Player-level observers live for the model's lifetime (not per item, since
        // the item is swapped when AirPlay engages).
        timeControlObs = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let s = player.timeControlStatus
            Task { @MainActor in self?.handleTimeControl(s) }
        }
        externalObs = player.observe(\.isExternalPlaybackActive, options: [.new]) { [weak self] player, _ in
            let active = player.isExternalPlaybackActive
            Task { @MainActor in self?.handleExternalPlayback(active) }
        }
        // Keep the AirPlay device name fresh (the audio route can resolve slightly
        // after external playback flips on).
        NotificationCenter.default.addObserver(
            self, selector: #selector(audioRouteChanged(_:)),
            name: AVAudioSession.routeChangeNotification, object: nil)

        Task { await load() }
    }

    private func configureAudioSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    /// Loads (or reloads) the stream. `preferLAN` addresses the playlist via the
    /// Wi-Fi IP so an AirPlay receiver can fetch it; `detect` arms native-capability
    /// detection (only on the first load — AirPlay reloads keep the prior verdict).
    private func load(preferLAN: Bool = false, detect: Bool = true) async {
        guard let source = stream.primary else { if detect { resolveUnsupported() }; return }
        guard let local = await LocalStreamProxy.shared.localURL(
            for: source.url, headers: source.headers, preferLAN: preferLAN) else {
            if detect { resolveUnsupported() }; return
        }
        currentURLIsLAN = preferLAN

        // Drop observers/notifications bound to the outgoing item.
        statusObs = nil; presentationObs = nil
        if let old = item {
            NotificationCenter.default.removeObserver(
                self, name: .AVPlayerItemFailedToPlayToEndTime, object: old)
        }

        let asset = AVURLAsset(url: local)
        let item = AVPlayerItem(asset: asset)
        self.item = item

        statusObs = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let status = item.status
            Task { @MainActor in self?.handleStatus(status) }
        }
        presentationObs = item.observe(\.presentationSize, options: [.new]) { [weak self] item, _ in
            let size = item.presentationSize
            Task { @MainActor in self?.handlePresentationSize(size) }
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(itemFailedToPlay(_:)),
            name: .AVPlayerItemFailedToPlayToEndTime, object: item)

        player.replaceCurrentItem(with: item)
        player.play()
        isPlaying = true

        guard detect else { return }
        // Absolute backstop: if nothing ever plays, don't hang on native forever.
        absoluteTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard let self, !self.didResolveDetection else { return }
            self.resolveUnsupported()
        }
    }

    /// AirPlay toggled: re-address the playlist so the receiver can reach it
    /// (LAN IP) or return to loopback for on-device playback. Reloads keep the
    /// native-capability verdict (no re-detection). Only relevant once native
    /// has been confirmed for this channel.
    private func handleExternalPlayback(_ active: Bool) {
        isExternalActive = active
        externalDeviceName = active ? Self.airPlayRouteName() : nil
        guard didResolveDetection else { return }
        if active, !currentURLIsLAN {
            Task { await load(preferLAN: true, detect: false) }
        } else if !active, currentURLIsLAN {
            Task { await load(preferLAN: false, detect: false) }
        }
    }

    /// The name of the current AirPlay audio/video output, if any.
    private static func airPlayRouteName() -> String? {
        AVAudioSession.sharedInstance().currentRoute.outputs
            .first { $0.portType == .airPlay }?.portName
    }

    @objc private nonisolated func audioRouteChanged(_ note: Notification) {
        Task { @MainActor in
            guard self.isExternalActive else { return }
            self.externalDeviceName = Self.airPlayRouteName()
        }
    }

    // MARK: - Detection handlers

    private func handleStatus(_ status: AVPlayerItem.Status) {
        switch status {
        case .failed:
            resolveUnsupported()
        case .readyToPlay:
            setupSubtitlesIfNeeded()
        default:
            break
        }
    }

    private func handlePresentationSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        resolveSupported()
    }

    private func handleTimeControl(_ status: AVPlayer.TimeControlStatus) {
        if status == .playing {
            isPlaying = true
            // Audio/playback is flowing — give the video a short grace to appear.
            // If it never does, this is an undecodable (HEVC-in-TS) channel.
            startVideoGrace()
        }
    }

    private func startVideoGrace() {
        guard !graceStarted else { return }
        graceStarted = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard let self, !self.didResolveDetection else { return }
            if let item = self.item, item.presentationSize == .zero {
                self.resolveUnsupported()
            }
        }
    }

    @objc private nonisolated func itemFailedToPlay(_ note: Notification) {
        Task { @MainActor in self.resolveUnsupported() }
    }

    private func resolveSupported() {
        guard !didResolveDetection else { return }
        didResolveDetection = true
        absoluteTimeout?.cancel(); absoluteTimeout = nil
        isBuffering = false
        onDidRenderVideo?()
        // If AirPlay was engaged before detection finished, re-address for the receiver.
        handleExternalPlayback(player.isExternalPlaybackActive)
    }

    private func resolveUnsupported() {
        guard !didResolveDetection else { return }
        didResolveDetection = true
        absoluteTimeout?.cancel(); absoluteTimeout = nil
        onCannotPlayVideo?()
    }

    // MARK: - Subtitles (HLS legible media selection)

    private func setupSubtitlesIfNeeded() {
        guard legibleGroup == nil, let item else { return }
        let asset = item.asset
        if #available(iOS 16.0, *) {
            Task { [weak self] in
                let group = try? await asset.loadMediaSelectionGroup(for: .legible)
                await MainActor.run { self?.applyLegibleGroup(group, item: item) }
            }
        } else {
            // iOS 15: the async loader doesn't exist; use the synchronous accessor.
            // The playlist is served locally, so this resolves without a network wait.
            applyLegibleGroup(asset.mediaSelectionGroup(forMediaCharacteristic: .legible), item: item)
        }
    }

    private func applyLegibleGroup(_ group: AVMediaSelectionGroup?, item: AVPlayerItem) {
        guard let group else { return }
        legibleGroup = group
        hasSubtitles = !group.options.isEmpty
        // Default off; VLC-style "on by default" isn't idiomatic for HLS CC.
        item.select(nil, in: group)
    }

    func toggleSubtitles() {
        subtitlesOn.toggle()
        guard let group = legibleGroup, let item else { return }
        if subtitlesOn {
            let localized = AVMediaSelectionGroup.mediaSelectionOptions(from: group.options, with: Locale.current)
            item.select(localized.first ?? group.options.first, in: group)
        } else {
            item.select(nil, in: group)
        }
    }

    // MARK: - Playback controls

    func play() { player.play(); isPlaying = true }
    func pause() { player.pause(); isPlaying = false }

    // MARK: - Picture in Picture

    private func setupPiP() {
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            pipSupported = false; return
        }
        guard let pip = AVPictureInPictureController(playerLayer: playerView.playerLayer) else {
            pipSupported = false; return
        }
        pip.delegate = self
        pip.canStartPictureInPictureAutomaticallyFromInline = true
        pipController = pip
        pipSupported = true
    }

    func togglePiP() {
        guard let pip = pipController else { return }
        if pip.isPictureInPictureActive { pip.stopPictureInPicture() }
        else { pip.startPictureInPicture() }
    }

    // MARK: - Teardown

    func teardown() {
        absoluteTimeout?.cancel(); absoluteTimeout = nil
        statusObs = nil; presentationObs = nil; timeControlObs = nil; externalObs = nil
        NotificationCenter.default.removeObserver(self)
        if let pip = pipController, pip.isPictureInPictureActive { pip.stopPictureInPicture() }
        pipController = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
    }
}

// MARK: - PiP delegate (AVKit calls these on the main thread)

extension NativePlayerModel: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in self.isPiPActive = true }
    }

    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        Task { @MainActor in
            self.pipWillRestore = true
            self.onPiPRestoreUI?()
            completionHandler(true)
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in
            self.isPiPActive = false
            if self.pipWillRestore {
                self.pipWillRestore = false
            } else {
                self.onPiPStopped?()
            }
        }
    }
}

// MARK: - Video surface

/// A UIView whose backing layer IS the AVPlayerLayer (so PiP has a real layer).
final class AVPlayerContainerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

struct NativeVideoView: UIViewRepresentable {
    let model: NativePlayerModel

    /// Return the model-owned view so the AVPlayerLayer + PiP controller persist
    /// across the player screen being torn down and re-presented (e.g. on PiP
    /// restore). Detach from any stale superview first.
    func makeUIView(context: Context) -> AVPlayerContainerView {
        model.playerView.removeFromSuperview()
        return model.playerView
    }

    func updateUIView(_ view: AVPlayerContainerView, context: Context) {}
}

// MARK: - AirPlay route picker

struct AirPlayRoutePickerView: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.tintColor = .white
        picker.activeTintColor = UIColor(Theme.accent)
        picker.prioritizesVideoDevices = true
        picker.backgroundColor = .clear
        return picker
    }
    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}
