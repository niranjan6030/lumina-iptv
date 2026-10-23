import AVFoundation
import AVKit
import SwiftUI
import LuminaCore

// MARK: - Persistent video surface + Picture in Picture

final class PlayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

/// Owns ONE video layer for the whole app lifetime. The player screen just re-parents it, so
/// Picture in Picture keeps running after the full-screen cover is dismissed.
@MainActor @Observable
final class PiPController: NSObject, AVPictureInPictureControllerDelegate {
    static let shared = PiPController()

    private(set) var isActive = false
    private(set) var isPossible = false
    @ObservationIgnored let hostView = PlayerUIView()
    @ObservationIgnored private var controller: AVPictureInPictureController?
    @ObservationIgnored private var possibleObs: NSKeyValueObservation?

    private override init() {
        super.init()
        hostView.backgroundColor = .black
        hostView.playerLayer.videoGravity = .resizeAspect
        hostView.playerLayer.player = PlayerController.shared.player
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        let c = AVPictureInPictureController(playerLayer: hostView.playerLayer)
        c?.delegate = self
        c?.canStartPictureInPictureAutomaticallyFromInline = true
        controller = c
        possibleObs = c?.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] c, _ in
            let v = c.isPictureInPicturePossible
            Task { @MainActor in self?.isPossible = v }
        }
    }

    var gravity: AVLayerVideoGravity {
        get { hostView.playerLayer.videoGravity }
        set { hostView.playerLayer.videoGravity = newValue }
    }

    func toggle() {
        guard let controller else { return }
        if controller.isPictureInPictureActive { controller.stopPictureInPicture() } else { controller.startPictureInPicture() }
    }

    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ c: AVPictureInPictureController) {
        Task { @MainActor in
            self.isActive = true
            UIState.shared.showPlayer = false // let the user browse while the floating window plays
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) {
        Task { @MainActor in self.isActive = false }
    }

    nonisolated func pictureInPictureController(
        _ c: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler done: @escaping (Bool) -> Void
    ) {
        Task { @MainActor in
            UIState.shared.showPlayer = true
            done(true)
        }
    }
}

struct VideoSurface: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black
        attach(PiPController.shared.hostView, to: container)
        return container
    }

    func updateUIView(_ ui: UIView, context: Context) {
        let host = PiPController.shared.hostView
        if host.superview !== ui { attach(host, to: ui) }
    }

    private func attach(_ host: UIView, to container: UIView) {
        host.removeFromSuperview()
        host.frame = container.bounds
        host.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(host)
    }
}

struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = .white
        v.activeTintColor = UIColor(Theme.accent)
        v.prioritizesVideoDevices = true
        return v
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

// MARK: - Screen

struct PlayerScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    private let player = PlayerController.shared
    private let pip = PiPController.shared

    @State private var overlay = true
    @State private var hideTask: Task<Void, Never>?
    @State private var scheduleFor: Channel?
    @State private var fill = false
    @State private var dragY: CGFloat = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VideoSurface().ignoresSafeArea()

            if player.audioOnly { audioOnlyBackdrop }

            statusLayer

            if overlay {
                VStack(spacing: 0) {
                    topBar
                    Spacer()
                    if player.isLive { liveInfo } else { vodControls }
                }
                .transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { toggleOverlay() }
        .gesture(
            DragGesture(minimumDistance: 40)
                .onEnded { v in
                    guard player.isLive, abs(v.translation.height) > abs(v.translation.width) * 1.5 else { return }
                    if v.translation.height < -60 { player.zap(1) } else if v.translation.height > 60 { player.zap(-1) }
                    showOverlayBriefly()
                }
        )
        .statusBarHidden(!overlay)
        .persistentSystemOverlays(.hidden)
        .animation(.smooth(duration: 0.25), value: overlay)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            showOverlayBriefly()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            hideTask?.cancel()
        }
        .sheet(item: $scheduleFor) { ScheduleView(channel: $0) }
        .preferredColorScheme(.dark)
    }

    // MARK: Overlay

    private func toggleOverlay() {
        overlay.toggle()
        if overlay { showOverlayBriefly() }
    }

    private func showOverlayBriefly() {
        overlay = true
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(4.5))
            guard !Task.isCancelled, player.isPlaying else { return }
            overlay = false
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            GlassIconButton(systemName: "chevron.down") { dismiss() }
            Spacer(minLength: 0)
            VStack(spacing: 2) {
                Text(player.title).font(.headline).lineLimit(1)
                if player.isLive { LiveDot() }
            }
            .padding(.horizontal, 16).padding(.vertical, 6)
            .glassCapsule()
            Spacer(minLength: 0)
            AirPlayButton().frame(width: 44, height: 44).glassCapsule(interactive: true)
            if pip.isPossible { GlassIconButton(systemName: "pip.enter") { pip.toggle() } }
            moreMenu
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var moreMenu: some View {
        Menu {
            if let ch = player.channel {
                Button { model.toggleFavorite(ch) } label: {
                    Label(model.isFavorite(ch) ? "Remove favorite" : "Add to favorites", systemImage: model.isFavorite(ch) ? "star.slash" : "star")
                }
                Button { scheduleFor = ch } label: { Label("Schedule & replay", systemImage: "calendar") }
            }
            Toggle(isOn: Binding(get: { player.audioOnly }, set: { player.setAudioOnly($0) })) {
                Label("Audio only (saves data)", systemImage: "headphones")
            }
            Button {
                fill.toggle()
                pip.gravity = fill ? .resizeAspectFill : .resizeAspect
            } label: { Label(fill ? "Fit to screen" : "Fill screen", systemImage: "arrow.up.left.and.arrow.down.right") }
            Menu {
                ForEach([15, 30, 45, 60, 90], id: \.self) { m in
                    Button("\(m) minutes") { player.setSleepTimer(minutes: m) }
                }
                if player.sleepEndsAt != nil { Button("Turn off", role: .destructive) { player.setSleepTimer(minutes: nil) } }
            } label: { Label(player.sleepEndsAt == nil ? "Sleep timer" : "Sleep timer on", systemImage: "moon.zzz") }
            MediaOptionsMenu()
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .glassCapsule(interactive: true)
    }

    // MARK: Live

    private var liveInfo: some View {
        let nn = player.channel.map { model.nowNext($0) }
        return VStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                if let p = nn?.now {
                    HStack {
                        Text(p.title).font(.title3.weight(.semibold)).lineLimit(2)
                        Spacer()
                        Text(Fmt.range(p)).font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    ProgressView(value: p.progress(at: Date())).tint(Theme.accent)
                    if let n = nn?.next { Text("Next · \(n.title) · \(Fmt.time.string(from: n.start))").font(.footnote).foregroundStyle(.secondary).lineLimit(1) }
                } else {
                    Text(player.channel.map { GroupLabel.parse($0.group).title } ?? "").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 28) {
                GlassIconButton(systemName: "backward.fill", size: 52) { player.zap(-1); showOverlayBriefly() }
                GlassIconButton(systemName: player.isPlaying || player.isBuffering ? "pause.fill" : "play.fill", size: 64, tint: Theme.accent.opacity(0.35)) {
                    player.togglePlayPause()
                }
                GlassIconButton(systemName: "forward.fill", size: 52) { player.zap(1); showOverlayBriefly() }
            }
        }
        .padding(18)
        .glass(28)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    // MARK: VOD

    private var vodControls: some View {
        VStack(spacing: 12) {
            VODScrubber()
            HStack(spacing: 28) {
                GlassIconButton(systemName: "gobackward.15", size: 52) { player.seek(by: -15); showOverlayBriefly() }
                GlassIconButton(systemName: player.isPlaying || player.isBuffering ? "pause.fill" : "play.fill", size: 64, tint: Theme.accent.opacity(0.35)) {
                    player.togglePlayPause()
                }
                GlassIconButton(systemName: "goforward.30", size: 52) { player.seek(by: 30); showOverlayBriefly() }
            }
        }
        .padding(18)
        .glass(28)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    // MARK: Status

    @ViewBuilder
    private var statusLayer: some View {
        switch player.status {
        case .loading:
            VStack(spacing: 10) {
                ProgressView().controlSize(.large).tint(.white)
                if let n = player.failoverNote { Text(n).font(.footnote).foregroundStyle(.secondary) }
            }
            .padding(20).glass(22)
        case .failed(let msg):
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.yellow)
                Text(msg).font(.callout).multilineTextAlignment(.center)
                HStack {
                    Button("Try again") { player.resume() }.glassButtonStyle(prominent: true)
                    if player.isLive { Button("Next channel") { player.zap(1) }.glassButtonStyle() }
                }
            }
            .padding(24).glass(26).padding(.horizontal, 32)
        default:
            if player.isBuffering && player.isPlaying == false { ProgressView().controlSize(.large).tint(.white) }
            else if let n = player.failoverNote {
                Text(n).font(.footnote.weight(.medium)).padding(.horizontal, 14).padding(.vertical, 8).glassCapsule()
                    .frame(maxHeight: .infinity, alignment: .top).padding(.top, 70)
            }
        }
    }

    private var audioOnlyBackdrop: some View {
        VStack(spacing: 16) {
            LogoView(url: player.channel?.logo, size: 140, corner: 32, symbol: "headphones")
            Text("Audio only").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppBackground())
    }
}

// MARK: - VOD scrubber

struct VODScrubber: View {
    private let player = PlayerController.shared
    @State private var position = 0.0
    @State private var duration = 1.0
    @State private var scrubbing = false
    private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 4) {
            Slider(value: $position, in: 0...max(duration, 1)) { editing in
                scrubbing = editing
                if !editing { player.player.seek(to: CMTime(seconds: position, preferredTimescale: 600)) }
            }
            .tint(Theme.accent)
            HStack {
                Text(Fmt.duration(position)).monospacedDigit()
                Spacer()
                Text("-" + Fmt.duration(max(0, duration - position))).monospacedDigit()
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .onReceive(timer) { _ in
            guard !scrubbing, let item = player.player.currentItem else { return }
            let d = item.duration.seconds
            if d.isFinite, d > 0 { duration = d }
            let t = player.player.currentTime().seconds
            if t.isFinite { position = t }
        }
    }
}

// MARK: - Audio / subtitle tracks

struct MediaOptionsMenu: View {
    @State private var audio: AVMediaSelectionGroup?
    @State private var subs: AVMediaSelectionGroup?
    @State private var tick = 0
    private let player = PlayerController.shared

    var body: some View {
        Group {
            if let audio, audio.options.count > 1 {
                Menu {
                    ForEach(audio.options, id: \.self) { o in
                        Button { select(o, in: audio) } label: {
                            Label(o.displayName, systemImage: isSelected(o, audio) ? "checkmark" : "")
                        }
                    }
                } label: { Label("Audio", systemImage: "speaker.wave.2") }
            }
            if let subs, !subs.options.isEmpty {
                Menu {
                    Button { select(nil, in: subs) } label: { Label("Off", systemImage: isSelected(nil, subs) ? "checkmark" : "") }
                    ForEach(subs.options, id: \.self) { o in
                        Button { select(o, in: subs) } label: {
                            Label(o.displayName, systemImage: isSelected(o, subs) ? "checkmark" : "")
                        }
                    }
                } label: { Label("Subtitles", systemImage: "captions.bubble") }
            }
        }
        .id(tick)
        .task(id: player.player.currentItem) { await load() }
    }

    private func load() async {
        guard let asset = player.player.currentItem?.asset else { audio = nil; subs = nil; return }
        audio = try? await asset.loadMediaSelectionGroup(for: .audible)
        subs = try? await asset.loadMediaSelectionGroup(for: .legible)
    }

    private func select(_ option: AVMediaSelectionOption?, in group: AVMediaSelectionGroup) {
        player.player.currentItem?.select(option, in: group)
        tick += 1
    }

    private func isSelected(_ option: AVMediaSelectionOption?, _ group: AVMediaSelectionGroup) -> Bool {
        player.player.currentItem?.currentMediaSelection.selectedMediaOption(in: group) == option
    }
}
