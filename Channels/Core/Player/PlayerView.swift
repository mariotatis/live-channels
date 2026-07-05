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

// MARK: - Full player screen with custom controls

struct PlayerView: View {
    @StateObject private var model: PlayerModel
    @Environment(\.dismiss) private var dismiss
    @State private var liveStore = LiveStore.shared

    init(stream: PlayableStream) {
        _model = StateObject(wrappedValue: PlayerModel(stream: stream))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VLCVideoView(model: model, fill: model.fillScreen).ignoresSafeArea()

            if let error = model.errorMessage {
                VStack(spacing: 16) {
                    Image(systemName: "play.slash.fill").font(.largeTitle).foregroundStyle(.white.opacity(0.7))
                    Text("Playback Unavailable").font(.headline).foregroundStyle(.white)
                    Text(error).font(.callout).foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center).padding(.horizontal, 40)
                    HStack(spacing: 12) {
                        Button("Try Again") { model.reload() }
                            .buttonStyle(.borderedProminent).tint(Theme.accent)
                        Button("Close") { model.teardown(); dismiss() }
                            .buttonStyle(.bordered).tint(.white)
                    }
                }
            } else if model.isBuffering {
                ProgressView().tint(.white).scaleEffect(1.4)
            }

            if model.showControls && model.errorMessage == nil { controlsOverlay }
        }
        .statusBarHidden()
        .contentShape(Rectangle())
        .onTapGesture { withAnimation { model.showControls.toggle() } }
        .onDisappear { model.teardown() }
    }

    private var controlsOverlay: some View {
        VStack {
            HStack {
                Button { model.teardown(); dismiss() } label: {
                    Image(systemName: "chevron.down").font(.title3.bold())
                }
                Text(model.stream.title).font(.headline).lineLimit(1)
                Spacer()
                if let channel = model.stream.channel {
                    Button {
                        liveStore.toggleFavorite(channel, columnId: model.stream.columnId ?? AppConfig.liveColumnId)
                    } label: {
                        Image(systemName: liveStore.isFavorite(channel) ? "heart.fill" : "heart")
                            .font(.title3)
                            .foregroundStyle(liveStore.isFavorite(channel) ? AnyShapeStyle(Theme.brandGradient) : AnyShapeStyle(.white))
                    }
                }
                if model.hasSubtitles {
                    Button { model.toggleSubtitles() } label: {
                        Image(systemName: model.subtitlesOn ? "captions.bubble.fill" : "captions.bubble")
                            .font(.title3)
                            .foregroundStyle(model.subtitlesOn ? AnyShapeStyle(Theme.brandGradient) : AnyShapeStyle(.white))
                    }
                }
                Button { model.fillScreen.toggle() } label: {
                    Image(systemName: model.fillScreen
                          ? "arrow.down.right.and.arrow.up.left"
                          : "arrow.up.left.and.arrow.down.right")
                        .font(.title3)
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
}
