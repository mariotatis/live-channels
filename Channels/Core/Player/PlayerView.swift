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
    weak var container: VLCContainerView?

    private var hasStarted = false
    private var didTeardown = false
    private var timeoutTask: Task<Void, Never>?

    init(stream: PlayableStream) {
        self.stream = stream
        super.init()
        configureAudioSession()
        mediaPlayer.delegate = self
        if let source = stream.primary {
            Task { await load(source) }
        }
    }

    private func configureAudioSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    /// Retry the current stream (e.g. after a transient CDN failure).
    func reload() {
        guard let source = stream.primary else { return }
        Task { await load(source) }
    }

    func load(_ source: StreamSource) async {
        errorMessage = nil
        isBuffering = true
        hasStarted = false

        guard let local = await LocalStreamProxy.shared.localURL(for: source.url, headers: source.headers) else {
            errorMessage = "Couldn’t start playback. Please try again."
            isBuffering = false
            return
        }
        let media = VLCMedia(url: local)
        media.addOption(":network-caching=1500")
        mediaPlayer.media = media
        mediaPlayer.play()
        isPlaying = true

        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard let self, !self.hasStarted, self.errorMessage == nil else { return }
            self.errorMessage = "Couldn’t start playback — this channel may be temporarily unavailable."
            self.isBuffering = false
        }
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
        case .error:
            errorMessage = "This channel can’t be played right now."
            isBuffering = false
        case .playing:
            errorMessage = nil
        case .paused:
            isPlaying = false
        default:
            break
        }
    }

    private func handleTimeChanged() {
        // Real frames are flowing → we've started.
        hasStarted = true
        isBuffering = false
        if errorMessage != nil { errorMessage = nil }
        if !isPlaying { isPlaying = mediaPlayer.isPlaying }
        refreshSubtitles()
        // Video dimensions may only become known once decoding starts — re-apply
        // the fill geometry now that the aspect ratio is available.
        container?.setNeedsLayout()
    }

    func teardown() {
        guard !didTeardown else { return }
        didTeardown = true
        timeoutTask?.cancel(); timeoutTask = nil
        mediaPlayer.delegate = nil
        mediaPlayer.stop()
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

    func makeUIView(context: Context) -> VLCContainerView {
        let container = VLCContainerView()
        container.player = model.mediaPlayer
        model.mediaPlayer.drawable = container.videoView
        model.container = container
        return container
    }

    func updateUIView(_ container: VLCContainerView, context: Context) {
        container.fill = fill
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

/// Owns the two playback engines and switches between them. Every channel starts
/// on the native (AVPlayer) engine; if it can't render video (HEVC-in-TS) we fall
/// back to VLC automatically. The player-selector gear is only offered once the
/// native engine has proven it can play the channel (`nativeSupported == true`).
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

    init(stream: PlayableStream) {
        self.stream = stream
        startNative()
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

    var showEngineGear: Bool { nativeSupported == true }

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
    @ObservedObject private var coordinator: PlaybackCoordinator
    @State private var liveStore = LiveStore.shared

    /// The coordinator is owned by PlaybackSession (so it can outlive this view
    /// for Picture in Picture) — the view only observes it.
    init(coordinator: PlaybackCoordinator) {
        _coordinator = ObservedObject(wrappedValue: coordinator)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            videoSurface

            if let error = coordinator.errorMessage {
                errorOverlay(error)
            } else if coordinator.isExternalActive {
                airPlayOverlay
            } else if coordinator.isBuffering {
                ProgressView().tint(.white).scaleEffect(1.4)
            }

            if coordinator.showControls && coordinator.errorMessage == nil { controlsOverlay }
        }
        .statusBarHidden()
        .contentShape(Rectangle())
        .onTapGesture { withAnimation { coordinator.showControls.toggle() } }
        .sheet(isPresented: $coordinator.showEngineSheet) { engineSheet }
    }

    @ViewBuilder
    private var videoSurface: some View {
        switch coordinator.engine {
        case .native:
            if let native = coordinator.native {
                NativeVideoView(model: native).ignoresSafeArea()
            }
        case .vlc:
            if let vlc = coordinator.vlc {
                VLCVideoView(model: vlc, fill: vlc.fillScreen).ignoresSafeArea()
            }
        }
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

    private var controlsOverlay: some View {
        VStack {
            HStack(spacing: 18) {
                Button { PlaybackSession.shared.dismiss() } label: {
                    Image(systemName: "chevron.down").font(.title3.bold())
                }
                Text(coordinator.stream.title).font(.headline).lineLimit(1)
                Spacer()

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

                    if coordinator.showEngineGear {
                        Button { coordinator.showEngineSheet = true } label: {
                            Image(systemName: "gearshape.fill").font(.title3)
                        }
                    }
                }
            }
            .foregroundStyle(.white)
            .padding()

            Spacer()
        }
        .background(
            LinearGradient(colors: [.black.opacity(0.6), .clear, .black.opacity(0.6)],
                           startPoint: .top, endPoint: .bottom).ignoresSafeArea()
        )
    }

    private var engineSheet: some View {
        NavigationStack {
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
                                    Image(systemName: "checkmark").foregroundStyle(Theme.accent).fontWeight(.semibold)
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
        .presentationDetents([.medium])
    }
}
