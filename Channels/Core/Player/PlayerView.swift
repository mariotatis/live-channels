//
//  PlayerView.swift
//  Channels
//
//  Live video player backed by MobileVLCKit (via VLCKitSPM). VLC is used for
//  every channel because a portion of the lineup streams HEVC-in-MPEG-TS, which
//  AVPlayer cannot decode (audio-only). VLC decodes H.264 and HEVC in TS, and
//  reaches the auth-gated playlist through LocalStreamProxy.
//

import SwiftUI
import Combine
import AVFoundation
import VLCKitSPM

@MainActor
final class PlayerModel: NSObject, ObservableObject, VLCMediaPlayerDelegate {
    @Published var isPlaying = true
    @Published var isBuffering = true
    @Published var showControls = true
    @Published var errorMessage: String?
    @Published var fillScreen = false
    @Published var hasSubtitles = false
    @Published var subtitlesOn = true

    let stream: PlayableStream
    let mediaPlayer = VLCMediaPlayer()
    /// A single, long-lived video view owned by the model. It is re-parented
    /// between the full-screen player and the mini player rather than recreated,
    /// so libvlc's video output stays attached and doesn't go black on the move
    /// (the same trick NativePlayer uses for its AVPlayerLayer).
    let containerView = VLCContainerView()

    private var hasStarted = false
    private var didTeardown = false
    private var timeoutTask: Task<Void, Never>?
    /// Desired mute state (multiview: only the focused tile is unmuted). Kept so
    /// it can be re-applied after each (re)load, since VLC resets audio on play.
    private var muted = false

    // MARK: Stall auto-recovery
    /// Watchdog that reconnects a stream that froze/paused/dropped mid-playback
    /// (network hiccup) without the user having to close & reopen the channel.
    private var watchdog: Task<Void, Never>?
    /// When frames last advanced. If this goes stale while we should be playing,
    /// the stream has stalled and we reconnect.
    private var lastProgressAt = Date()
    /// Auto-reconnect attempts since the last successful playback; capped so a
    /// genuinely dead channel eventually surfaces an error instead of looping.
    private var autoRecoverCount = 0
    private let maxAutoRecover = 3
    /// No new frames for this long (while playing) ⇒ treat as stalled.
    private let stallTimeout: TimeInterval = 4

    init(stream: PlayableStream) {
        self.stream = stream
        super.init()
        configureAudioSession()
        mediaPlayer.delegate = self
        containerView.player = mediaPlayer
        mediaPlayer.drawable = containerView.videoView
        if let source = stream.primary {
            Task { await load(source) }
        }
    }

    private func configureAudioSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    /// Retry the current stream (user-triggered, e.g. the refresh button). Clears
    /// the auto-recovery budget since this is a deliberate fresh start.
    func reload() {
        guard let source = stream.primary else { return }
        autoRecoverCount = 0
        Task { await load(source) }
    }

    func load(_ source: StreamSource) async {
        errorMessage = nil
        isBuffering = true
        hasStarted = false
        lastProgressAt = Date()

        guard let local = await LocalStreamProxy.shared.localURL(for: source.url, headers: source.headers) else {
            errorMessage = "Couldn’t start playback. Please try again."
            isBuffering = false
            return
        }
        let media = VLCMedia(url: local)
        media.addOption(":network-caching=1500")
        mediaPlayer.media = media
        mediaPlayer.play()
        mediaPlayer.audio?.isMuted = muted
        isPlaying = true
        startWatchdog()

        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard let self, !self.hasStarted, self.errorMessage == nil else { return }
            self.errorMessage = "Couldn’t start playback — this channel may be temporarily unavailable."
            self.isBuffering = false
        }
    }

    // MARK: Stall auto-recovery

    /// Silent reconnect after a mid-playback stall/drop, up to `maxAutoRecover`
    /// attempts; past that, surface the error instead of looping forever.
    private func autoRecover() {
        guard !didTeardown, let source = stream.primary else { return }
        guard autoRecoverCount < maxAutoRecover else {
            errorMessage = "This channel can’t be played right now."
            isBuffering = false
            return
        }
        autoRecoverCount += 1
        isBuffering = true
        lastProgressAt = Date()
        Task { await load(source) }
    }

    /// Recover from an interruption (error/ended/stopped) only if we'd actually
    /// been playing and aren't already showing an error / tearing down.
    private func recoverIfInterrupted() {
        guard !didTeardown, hasStarted, errorMessage == nil else { return }
        autoRecover()
    }

    /// Poll for a frozen stream: if frames stopped advancing (or VLC quietly
    /// paused) for `stallTimeout` while we should be playing, reconnect.
    private func startWatchdog() {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                guard !self.didTeardown, self.hasStarted, self.errorMessage == nil else { continue }
                if Date().timeIntervalSince(self.lastProgressAt) > self.stallTimeout {
                    self.autoRecover()
                }
            }
        }
    }

    /// Multiview audio focus: mute/unmute this player. Re-applied on each load.
    func setMuted(_ value: Bool) {
        muted = value
        mediaPlayer.audio?.isMuted = value
    }

    func togglePlay() {
        if mediaPlayer.isPlaying {
            mediaPlayer.pause()
            isPlaying = false
        } else {
            mediaPlayer.play()
            isPlaying = true
        }
    }

    // MARK: Subtitles

    /// Track ids VLC reports (excluding the -1 "Disable" entry).
    private var subtitleTrackIds: [Int] {
        ((mediaPlayer.videoSubTitlesIndexes as? [NSNumber]) ?? []).map(\.intValue).filter { $0 >= 0 }
    }

    /// Reflects availability and enforces the user's on/off choice (VLC
    /// re-announces/auto-selects subtitle tracks on live streams).
    private func refreshSubtitles() {
        let ids = subtitleTrackIds
        hasSubtitles = !ids.isEmpty
        guard let first = ids.first else { return }
        if subtitlesOn {
            if mediaPlayer.currentVideoSubTitleIndex < 0 { mediaPlayer.currentVideoSubTitleIndex = Int32(first) }
        } else {
            if mediaPlayer.currentVideoSubTitleIndex >= 0 { mediaPlayer.currentVideoSubTitleIndex = -1 }
        }
    }

    func toggleSubtitles() {
        subtitlesOn.toggle()
        if subtitlesOn, let first = subtitleTrackIds.first {
            mediaPlayer.currentVideoSubTitleIndex = Int32(first)
        } else {
            mediaPlayer.currentVideoSubTitleIndex = -1
        }
    }

    // MARK: VLCMediaPlayerDelegate
    // VLC delivers these on a background thread — hop to the main actor before
    // touching the player's layer or any @Published state.

    nonisolated func mediaPlayerStateChanged(_ aNotification: Notification) {
        Task { @MainActor in self.handleStateChanged() }
    }

    nonisolated func mediaPlayerTimeChanged(_ aNotification: Notification) {
        Task { @MainActor in self.handleTimeChanged() }
    }

    private func handleStateChanged() {
        switch mediaPlayer.state {
        case .playing:
            errorMessage = nil
            isPlaying = true
        case .paused:
            // No manual pause exists in the UI, so a pause is involuntary — but
            // let the watchdog confirm it's really stuck before reconnecting.
            isPlaying = false
        case .error:
            if hasStarted {
                recoverIfInterrupted()          // dropped mid-playback → reconnect
            } else {
                errorMessage = "This channel can’t be played right now."
                isBuffering = false
            }
        case .ended, .stopped:
            recoverIfInterrupted()              // live shouldn't end → reconnect
        default:
            break
        }
    }

    private func handleTimeChanged() {
        // Real frames are flowing → we've started (and playback is healthy).
        hasStarted = true
        isBuffering = false
        lastProgressAt = Date()
        autoRecoverCount = 0
        if errorMessage != nil { errorMessage = nil }
        if !isPlaying { isPlaying = mediaPlayer.isPlaying }
        refreshSubtitles()
        // Video dimensions may only become known once decoding starts — re-apply
        // the fill geometry now that the aspect ratio is available.
        containerView.setNeedsLayout()
    }

    func teardown() {
        guard !didTeardown else { return }
        didTeardown = true
        watchdog?.cancel(); watchdog = nil
        timeoutTask?.cancel(); timeoutTask = nil
        mediaPlayer.delegate = nil
        mediaPlayer.drawable = nil
        // VLCMediaPlayer.stop() is synchronous and can block the main thread
        // (it joins the decode/output threads). Tearing down several tiles at
        // once that way freezes the UI when closing the player, so stop off the
        // main thread; the closure retains the player until stop() returns.
        let player = mediaPlayer
        DispatchQueue.global(qos: .userInitiated).async {
            player.stop()
        }
    }
}

/// Hosts the VLC video output. VLC draws into an inner view; for "fill" we scale
/// that inner view (via transform) to cover the screen. The scaling is done in
/// layoutSubviews so it always uses valid bounds (and survives rotation).
final class VLCContainerView: UIView {
    let videoView = UIView()
    weak var player: VLCMediaPlayer?
    var fill = false { didSet { if fill != oldValue { setNeedsLayout() } } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true
        isUserInteractionEnabled = false  // taps fall through to SwiftUI controls
        videoView.backgroundColor = .black
        addSubview(videoView)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        videoView.transform = .identity
        videoView.frame = bounds
        let scale = coverScale()
        if scale != 1 { videoView.transform = CGAffineTransform(scaleX: scale, y: scale) }
    }

    /// Aspect ratio of the video, from VLC (falling back to media track info,
    /// then 16:9) since `videoSize` is often 0 early / on the simulator.
    private var videoAspect: CGFloat {
        if let vs = player?.videoSize, vs.width > 0, vs.height > 0 { return vs.width / vs.height }
        if let tracks = player?.media?.tracksInformation as? [[String: Any]] {
            for t in tracks where (t["type"] as? String) == "video" {
                if let w = (t["width"] as? NSNumber)?.doubleValue,
                   let h = (t["height"] as? NSNumber)?.doubleValue, w > 0, h > 0 {
                    return CGFloat(w / h)
                }
            }
        }
        return 16.0 / 9.0
    }

    private func coverScale() -> CGFloat {
        guard fill, bounds.width > 0, bounds.height > 0 else { return 1 }
        let viewAspect = bounds.width / bounds.height
        let va = videoAspect
        return va > viewAspect ? va / viewAspect : viewAspect / va
    }
}

struct VLCVideoView: UIViewRepresentable {
    let model: PlayerModel
    let fill: Bool

    /// Return the model-owned view (detached from any old superview) so the same
    /// VLC surface moves between the full-screen and mini players without the
    /// video output going black.
    func makeUIView(context: Context) -> VLCContainerView {
        model.containerView.removeFromSuperview()
        return model.containerView
    }

    func updateUIView(_ container: VLCContainerView, context: Context) {
        container.fill = fill
    }
}

/// The raw video output for the current engine, with no controls. Shared by the
/// full-screen `PlayerView` and the floating `MiniPlayerView` so the same
/// VLC/AVPlayer model drives whichever surface is currently on screen.
struct PlaybackVideoSurface: View {
    @ObservedObject var coordinator: PlaybackCoordinator
    /// Overrides the VLC fill mode; nil honors the user's toggle (full screen),
    /// the mini player passes `false` so nothing is cropped in the small window.
    var fill: Bool? = nil

    var body: some View {
        switch coordinator.engine {
        case .native:
            if let native = coordinator.native {
                NativeVideoView(model: native)
            }
        case .vlc:
            if let vlc = coordinator.vlc {
                VLCVideoView(model: vlc, fill: fill ?? vlc.fillScreen)
            }
        }
    }
}

// MARK: - Engine coordination

enum PlayerEngine: String, CaseIterable, Identifiable {
    case native, vlc
    var id: String { rawValue }
    var title: String { self == .native ? "Native Player" : "VLC Player" }
    var subtitle: String {
        self == .native ? "AirPlay & Picture in Picture" : "Broadest codec support"
    }
}

/// Owns the two playback engines and switches between them. Channels default to
/// the VLC engine (broadest codec support); the user can opt into the native
/// (AVPlayer) engine from the always-available player-selector gear to get
/// AirPlay / Picture in Picture. If the native engine can't render a channel
/// (HEVC-in-TS) it falls back to VLC automatically.
@MainActor
final class PlaybackCoordinator: ObservableObject {
    let stream: PlayableStream

    @Published var engine: PlayerEngine = .native
    /// nil = still detecting, true = native works, false = fell back to VLC.
    @Published var nativeSupported: Bool? = nil
    @Published var showControls = true
    @Published var showEngineSheet = false

    @Published private(set) var native: NativePlayerModel?
    @Published private(set) var vlc: PlayerModel?

    /// Set by PlaybackSession: re-present the player UI when PiP restore is tapped.
    var onRestoreUI: (() -> Void)?
    /// Set by PlaybackSession: PiP was closed by the user (not for restore).
    var onPiPStopped: (() -> Void)?

    private var cancellables = Set<AnyCancellable>()

    init(stream: PlayableStream, startOn engine: PlayerEngine = .native) {
        self.stream = stream
        switch engine {
        case .native:
            startNative()
        case .vlc:
            // Start straight on VLC (used by the mini player) — skip native
            // detection entirely.
            ensureVLC(fresh: true)
            self.engine = .vlc
        }
    }

    var isPiPActive: Bool { native?.isPiPActive ?? false }

    // MARK: Aggregated state for the shared overlay

    var isBuffering: Bool {
        switch engine {
        case .native: return native?.isBuffering ?? true
        case .vlc:    return vlc?.isBuffering ?? true
        }
    }

    /// Only VLC surfaces a hard error to the user — native failures fall back to VLC.
    var errorMessage: String? {
        engine == .vlc ? vlc?.errorMessage : nil
    }

    // Always offer the engine selector: playback now defaults to VLC, and the
    // gear is how the user opts into the native player (AirPlay / PiP).
    var showEngineGear: Bool { true }

    /// The engine has been decided AND is actually playing — only then are the
    /// trailing controls valid to show (avoids flashing native-only icons like
    /// AirPlay/PiP while we're still detecting whether AVPlayer can play it).
    var controlsReady: Bool {
        switch engine {
        case .native: return nativeSupported == true && !(native?.isBuffering ?? true)
        case .vlc:    return !(vlc?.isBuffering ?? true)
        }
    }

    /// Video is playing on an AirPlay device (local screen is black) → show a placeholder.
    var isExternalActive: Bool { engine == .native && (native?.isExternalActive ?? false) }
    var externalDeviceName: String? { native?.externalDeviceName }

    var fillScreen: Bool {
        switch engine {
        case .native: return native?.fillScreen ?? false
        case .vlc:    return vlc?.fillScreen ?? false
        }
    }

    var hasSubtitles: Bool {
        switch engine {
        case .native: return native?.hasSubtitles ?? false
        case .vlc:    return vlc?.hasSubtitles ?? false
        }
    }

    var subtitlesOn: Bool {
        switch engine {
        case .native: return native?.subtitlesOn ?? false
        case .vlc:    return vlc?.subtitlesOn ?? false
        }
    }

    // MARK: User actions

    func toggleFill() {
        switch engine {
        case .native: native?.fillScreen.toggle()
        case .vlc:    vlc?.fillScreen.toggle()
        }
    }

    func toggleSubtitles() {
        switch engine {
        case .native: native?.toggleSubtitles()
        case .vlc:    vlc?.toggleSubtitles()
        }
    }

    func retryVLC() { vlc?.reload() }

    /// Refresh the focused channel — restart its player connection (e.g. after a
    /// network hiccup stalled the stream), on whichever engine it's using.
    func reload() {
        switch engine {
        case .native: native?.reload()
        case .vlc:    vlc?.reload()
        }
    }

    /// Multiview audio focus: only the focused tile plays sound.
    private(set) var isMuted = false
    func setMuted(_ value: Bool) {
        isMuted = value
        native?.setMuted(value)
        vlc?.setMuted(value)
    }

    func select(_ target: PlayerEngine) {
        guard target != engine else { return }
        switch target {
        case .vlc:
            native?.teardown(); native = nil
            ensureVLC(fresh: true)
            engine = .vlc
        case .native:
            vlc?.teardown(); vlc = nil
            startNative()
        }
    }

    // MARK: Engine lifecycle

    private func startNative() {
        let model = NativePlayerModel(stream: stream)
        model.onDidRenderVideo = { [weak self] in
            guard let self, self.engine == .native else { return }
            self.nativeSupported = true
        }
        model.onCannotPlayVideo = { [weak self] in
            guard let self, self.engine == .native else { return }
            self.nativeSupported = false
            self.fallbackToVLC()
        }
        model.onPiPRestoreUI = { [weak self] in self?.onRestoreUI?() }
        model.onPiPStopped = { [weak self] in self?.onPiPStopped?() }
        model.setMuted(isMuted)
        bind(model)
        native = model
        engine = .native
    }

    private func fallbackToVLC() {
        native?.teardown(); native = nil
        ensureVLC(fresh: true)
        engine = .vlc
    }

    private func ensureVLC(fresh: Bool) {
        if vlc == nil {
            let model = PlayerModel(stream: stream)   // auto-plays on init
            model.setMuted(isMuted)
            bind(model)
            vlc = model
        } else if fresh {
            vlc?.reload()
        }
    }

    /// Re-publish sub-model changes so the shared SwiftUI controls stay in sync.
    private func bind(_ object: any ObservableObject) {
        (object.objectWillChange as? ObservableObjectPublisher)?
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    func teardown() {
        native?.teardown(); native = nil
        vlc?.teardown(); vlc = nil
        cancellables.removeAll()
    }
}

// MARK: - Full player screen with custom controls

struct PlayerView: View {
    @ObservedObject private var session = PlaybackSession.shared
    @State private var showAddSheet = false
    @Environment(\.verticalSizeClass) private var vSizeClass

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let active = session.coordinator {
                if session.tiles.count == 1 {
                    SinglePlayerContent(coordinator: active, showAddSheet: $showAddSheet)
                } else {
                    multiView(active: active)
                }
            }
        }
        .statusBarHidden()
        .sheet(isPresented: $showAddSheet) { AddChannelSheet { showAddSheet = false } }
    }

    // MARK: Multiview mosaic

    @ViewBuilder
    private func multiView(active: PlaybackCoordinator) -> some View {
        ZStack {
            tilesGrid()
            // In the mosaic the top bar is always visible and drives the focused tile.
            PlayerControlsBar(coordinator: active, showAddSheet: $showAddSheet)
        }
    }

    /// Portrait → tiles stacked vertically. Landscape → side-by-side (≤2) or a
    /// 2×2 grid (3–4). Every tile gets an equal share of the screen.
    @ViewBuilder
    private func tilesGrid() -> some View {
        let count = session.tiles.count
        let landscape = vSizeClass == .compact
        if landscape && count <= 2 {
            HStack(spacing: 2) { ForEach(0..<count, id: \.self) { tile($0) } }
        } else if landscape {
            VStack(spacing: 2) {
                HStack(spacing: 2) { tile(0); tile(1) }
                HStack(spacing: 2) {
                    tile(2)
                    if count > 3 { tile(3) } else { Color.black.frame(maxWidth: .infinity, maxHeight: .infinity) }
                }
            }
        } else {
            VStack(spacing: 2) { ForEach(0..<count, id: \.self) { tile($0) } }
        }
    }

    private func tile(_ index: Int) -> some View {
        TileView(
            coordinator: session.tiles[index],
            isActive: index == session.activeIndex,
            canRemove: session.tiles.count > 1,
            onSelect: { session.setActive(index) },
            onRemove: { session.removeTile(at: index) }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Single-channel player (full-screen, custom controls)

private struct SinglePlayerContent: View {
    @ObservedObject var coordinator: PlaybackCoordinator
    @Binding var showAddSheet: Bool

    var body: some View {
        ZStack {
            PlaybackVideoSurface(coordinator: coordinator)
                .id(ObjectIdentifier(coordinator))
                .ignoresSafeArea()

            if let error = coordinator.errorMessage {
                errorOverlay(error)
            } else if coordinator.isExternalActive {
                airPlayOverlay
            } else if coordinator.isBuffering {
                ProgressView().tint(.white).scaleEffect(1.4)
            }

            if coordinator.showControls && coordinator.errorMessage == nil {
                PlayerControlsBar(coordinator: coordinator, showAddSheet: $showAddSheet)
            }
        }
        // Channel name, bottom-left — shown with the controls (hidden when the
        // player is tapped into immersive mode).
        .overlay(alignment: .bottomLeading) {
            if coordinator.showControls && coordinator.errorMessage == nil {
                ChannelNameLabel(text: coordinator.stream.title).padding()
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { withAnimation { coordinator.showControls.toggle() } }
        .sheet(isPresented: $coordinator.showEngineSheet) { engineSheet }
    }

    private var airPlayOverlay: some View {
        VStack(spacing: 14) {
            Image(systemName: "airplayvideo")
                .font(.system(size: 64))
                .foregroundStyle(.white)
            Text(coordinator.externalDeviceName.map { "Playing on \($0)" } ?? "AirPlay")
                .font(.headline)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }

    private func errorOverlay(_ error: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "play.slash.fill").font(.largeTitle).foregroundStyle(.white.opacity(0.7))
            Text("Playback Unavailable").font(.headline).foregroundStyle(.white)
            Text(error).font(.callout).foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center).padding(.horizontal, 40)
            HStack(spacing: 12) {
                Button("Try Again") { coordinator.retryVLC() }
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
                Button("Close") { PlaybackSession.shared.endCurrent() }
                    .buttonStyle(.bordered).tint(.white)
            }
        }
    }

    private var engineSheet: some View {
        NavContainer {
            List {
                Section {
                    ForEach(PlayerEngine.allCases) { option in
                        Button {
                            coordinator.select(option)
                            coordinator.showEngineSheet = false
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.title).foregroundStyle(Theme.textPrimary)
                                    Text(option.subtitle).font(.caption).foregroundStyle(Theme.textSecondary)
                                }
                                Spacer()
                                if coordinator.engine == option {
                                    Image(systemName: "checkmark").foregroundStyle(Theme.accent).font(.body.weight(.semibold))
                                }
                            }
                        }
                    }
                } footer: {
                    Text("The native player supports AirPlay and Picture in Picture. Some channels stream in a format only the VLC player can decode.")
                }
            }
            .navigationTitle("Player")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { coordinator.showEngineSheet = false }
                }
            }
        }
        .mediumDetentIfAvailable()
    }
}

// MARK: - Shared top control bar (acts on the focused coordinator)

private struct PlayerControlsBar: View {
    @ObservedObject var coordinator: PlaybackCoordinator
    @ObservedObject private var liveStore = LiveStore.shared
    @ObservedObject private var session = PlaybackSession.shared
    @Binding var showAddSheet: Bool

    var body: some View {
        VStack {
            HStack(spacing: 18) {
                // Chevron-down shrinks the player into the floating mini player
                // and keeps the (focused) stream playing while the user browses.
                Button { PlaybackSession.shared.minimize() } label: {
                    Image(systemName: "chevron.down").font(.title3.weight(.bold))
                }
                .accessibilityLabel("Minimize")
                // The channel name lives at the bottom-left of each tile now, so a
                // single title up here doesn't make sense once there are several.
                Spacer()

                // "+" adds another channel to the mosaic (up to maxTiles); sits
                // just left of the favorite heart.
                if session.canAddMore {
                    Button { showAddSheet = true } label: {
                        Image(systemName: "plus").font(.title3.weight(.bold))
                    }
                    .accessibilityLabel("Add Channel")
                }

                // Trailing controls appear only once the engine is resolved and
                // playing, so no invalid/native-only icon flashes during detection.
                if coordinator.controlsReady {
                    if let channel = coordinator.stream.channel {
                        Button {
                            liveStore.toggleFavorite(channel, columnId: coordinator.stream.columnId ?? AppConfig.liveColumnId)
                        } label: {
                            Image(systemName: liveStore.isFavorite(channel) ? "heart.fill" : "heart")
                                .font(.title3)
                                .foregroundStyle(liveStore.isFavorite(channel) ? AnyShapeStyle(Theme.brandGradient) : AnyShapeStyle(.white))
                        }
                    }

                    if coordinator.hasSubtitles {
                        Button { coordinator.toggleSubtitles() } label: {
                            Image(systemName: coordinator.subtitlesOn ? "captions.bubble.fill" : "captions.bubble")
                                .font(.title3)
                                .foregroundStyle(coordinator.subtitlesOn ? AnyShapeStyle(Theme.brandGradient) : AnyShapeStyle(.white))
                        }
                    }

                    // AirPlay + PiP are native-engine only (VLC can't feed them).
                    if coordinator.engine == .native, let native = coordinator.native {
                        AirPlayRoutePickerView()
                            .frame(width: 26, height: 26)
                        if native.pipSupported {
                            Button { native.togglePiP() } label: {
                                Image(systemName: "pip.enter").font(.title3)
                            }
                        }
                    }

                    Button { coordinator.toggleFill() } label: {
                        Image(systemName: coordinator.fillScreen
                              ? "arrow.down.right.and.arrow.up.left"
                              : "arrow.up.left.and.arrow.down.right")
                            .font(.title3)
                    }

                    // Refresh the focused channel (reconnect a stalled stream).
                    Button { coordinator.reload() } label: {
                        Image(systemName: "arrow.clockwise").font(.title3)
                    }
                    .accessibilityLabel("Refresh Channel")

                    if coordinator.showEngineGear {
                        Button { coordinator.showEngineSheet = true } label: {
                            Image(systemName: "gearshape.fill").font(.title3)
                        }
                    }
                }

                // Always available: fully close all channels and exit the player.
                Button { PlaybackSession.shared.endCurrent() } label: {
                    Image(systemName: "xmark").font(.title3.weight(.bold))
                }
                .accessibilityLabel("Close")
            }
            .foregroundStyle(.white)
            .padding()

            Spacer()
        }
        .background(
            LinearGradient(colors: [.black.opacity(0.6), .clear, .black.opacity(0.6)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)   // don't eat taps meant for the tiles below
        )
    }
}

// MARK: - One tile in the multiview mosaic

private struct TileView: View {
    @ObservedObject var coordinator: PlaybackCoordinator
    let isActive: Bool
    let canRemove: Bool
    let onSelect: () -> Void
    let onRemove: () -> Void

    var body: some View {
        ZStack {
            Color.black
            PlaybackVideoSurface(coordinator: coordinator)
                .id(ObjectIdentifier(coordinator))

            if coordinator.isBuffering {
                ProgressView().tint(.white)
            } else if coordinator.errorMessage != nil {
                Image(systemName: "play.slash.fill")
                    .font(.title).foregroundStyle(.white.opacity(0.6))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(isActive ? Theme.accent : .white.opacity(0.08),
                              lineWidth: isActive ? 2 : 1)
        )
        // Audio-focus indicator, top-left (the focused tile is the one with sound).
        .overlay(alignment: .topLeading) {
            Image(systemName: isActive ? "speaker.wave.2.fill" : "speaker.slash.fill")
                .font(.caption2).foregroundStyle(.white)
                .padding(6).background(.black.opacity(0.5), in: Circle())
                .padding(6)
        }
        // Remove "×", vertically centered on the right edge — clear of the top
        // control bar that overlaps the first tile.
        .overlay(alignment: .trailing) {
            if canRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold)).foregroundStyle(.white)
                        .padding(8).background(.black.opacity(0.5), in: Circle())
                }
                .padding(.trailing, 8)
            }
        }
        // Channel name, bottom-left of this tile's space.
        .overlay(alignment: .bottomLeading) {
            ChannelNameLabel(text: coordinator.stream.title).padding(8)
        }
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
    }
}

/// Small channel-name pill shown at the bottom-left of a video surface.
private struct ChannelNameLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption).fontWeight(.semibold)
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.black.opacity(0.55), in: Capsule())
    }
}
