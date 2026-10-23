import AVFoundation
import MediaPlayer
import Observation
import UIKit
import LuminaCore

/// One AVPlayer shared by the phone UI, lock screen, AirPlay and CarPlay.
/// Owns: stream failover, now-playing info, remote commands, sleep timer, VOD progress.
@MainActor @Observable
final class PlayerController {
    static let shared = PlayerController()

    enum Status: Equatable {
        case idle, loading, playing, paused
        case failed(String)
    }

    let player = AVPlayer()

    private(set) var status: Status = .idle
    private(set) var channel: Channel?
    private(set) var vod: PlayableVOD?
    private(set) var zapList: [Channel] = []
    private(set) var isBuffering = false
    private(set) var failoverNote: String?
    private(set) var sleepEndsAt: Date?
    private(set) var audioOnly = false

    var isLive: Bool { vod == nil && channel != nil }
    var hasMedia: Bool { channel != nil || vod != nil }
    var title: String { channel?.name ?? vod?.title ?? "" }
    var isPlaying: Bool { status == .playing }
    private var isFailed: Bool { if case .failed = status { true } else { false } }

    // MARK: Internals

    @ObservationIgnored private var candidates: [StreamEndpoint] = []
    @ObservationIgnored private var candidateIndex = 0
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var wantsPlay = false
    @ObservationIgnored private var itemObservers: [NSKeyValueObservation] = []
    @ObservationIgnored private var tokens: [NSObjectProtocol] = []      // app-lifetime observers
    @ObservationIgnored private var itemTokens: [NSObjectProtocol] = []  // per-stream observers
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    @ObservationIgnored private var sleepTask: Task<Void, Never>?
    @ObservationIgnored private var metaTask: Task<Void, Never>?
    @ObservationIgnored private var artwork: MPMediaItemArtwork?
    @ObservationIgnored private var vodQueue: [PlayableVOD] = []
    @ObservationIgnored private var resumeAt: TimeInterval = 0
    @ObservationIgnored private var tcsObserver: NSKeyValueObservation?
    @ObservationIgnored private var configured = false

    private init() {}

    /// Call once at launch (phone) or when CarPlay connects, whichever comes first.
    func configureIfNeeded() {
        guard !configured else { return }
        configured = true
        player.allowsExternalPlayback = true
        player.automaticallyWaitsToMinimizeStalling = true
        player.preventsDisplaySleepDuringVideoPlayback = true

        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)

        tcsObserver = player.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            let s = p.timeControlStatus
            Task { @MainActor in self?.timeControlChanged(s) }
        }
        tokens.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] n in
            let type = (n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            let opts = (n.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt).map(AVAudioSession.InterruptionOptions.init)
            Task { @MainActor in
                guard let self else { return }
                if type == .began { self.pause() }
                else if type == .ended, opts?.contains(.shouldResume) == true, self.hasMedia { self.resume() }
            }
        })
        tokens.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] n in
            let reason = (n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init)
            Task { @MainActor in if reason == .oldDeviceUnavailable { self?.pause() } }
        })
        configureRemoteCommands()
    }

    // MARK: - Live

    func play(_ channel: Channel, in list: [Channel]? = nil) {
        configureIfNeeded()
        let s = AppModel.shared.user.settings
        vod = nil
        vodQueue = []
        removeTimeObserver()
        self.channel = channel
        if let list, !list.isEmpty { zapList = list }
        else if zapList.isEmpty || !zapList.contains(where: { $0.id == channel.id }) { zapList = AppModel.shared.visibleChannels }
        var c = channel.streams.flatMap { StreamCandidates.make(for: $0, rewriteTS: s.rewriteTSToHLS) }
        if !s.autoFailover { c = Array(c.prefix(1)) }
        candidates = c
        candidateIndex = 0
        failoverNote = nil
        resumeAt = 0
        AppModel.shared.noteWatched(channel)
        Task { await AppModel.shared.ensureGuide(for: channel) }
        startCandidate()
        startMetaTimer()
        loadArtwork(channel.logo)
    }

    func zap(_ delta: Int) {
        guard let ch = channel, !zapList.isEmpty else { return }
        let i = zapList.firstIndex(where: { $0.id == ch.id }) ?? 0
        let n = zapList.count
        var j = (i + delta + n) % n
        // Skip PIN-locked groups while zapping.
        var guardCount = 0
        while AppModel.shared.isLocked(group: zapList[j].group), guardCount < n {
            j = (j + delta + n) % n
            guardCount += 1
        }
        play(zapList[j])
    }

    // MARK: - VOD

    func play(_ item: PlayableVOD, queue: [PlayableVOD] = [], resumeAt: TimeInterval = 0) {
        configureIfNeeded()
        channel = nil
        vod = item
        vodQueue = queue
        candidates = [item.endpoint]
        candidateIndex = 0
        failoverNote = nil
        self.resumeAt = resumeAt
        startCandidate()
        loadArtwork(item.poster)
        metaTask?.cancel()
    }

    // MARK: - Transport

    func pause() {
        wantsPlay = false
        player.pause()
        if status == .playing || status == .loading { status = .paused }
        updateNowPlaying()
    }

    func resume() {
        guard hasMedia else { return }
        wantsPlay = true
        try? AVAudioSession.sharedInstance().setActive(true)
        if case .failed = status { candidateIndex = 0; startCandidate(); return }
        player.play()
        updateNowPlaying()
    }

    func togglePlayPause() { player.timeControlStatus == .paused ? resume() : pause() }

    func stop() {
        generation += 1
        wantsPlay = false
        watchdog?.cancel()
        metaTask?.cancel()
        saveVODProgress(final: true)
        removeTimeObserver()
        tearDownItem()
        player.replaceCurrentItem(with: nil)
        channel = nil
        vod = nil
        status = .idle
        isBuffering = false
        failoverNote = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func setAudioOnly(_ on: Bool) {
        audioOnly = on
        player.currentItem?.preferredPeakBitRate = on ? 400_000 : 0
    }

    func seek(by seconds: Double) {
        guard vod != nil else { return }
        let t = player.currentTime().seconds + seconds
        player.seek(to: CMTime(seconds: max(0, t), preferredTimescale: 600))
    }

    // MARK: - Sleep timer

    func setSleepTimer(minutes: Int?) {
        sleepTask?.cancel()
        guard let minutes else { sleepEndsAt = nil; return }
        let end = Date().addingTimeInterval(Double(minutes) * 60)
        sleepEndsAt = end
        sleepTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Double(minutes) * 60))
            guard !Task.isCancelled, let self else { return }
            // Fade out over ~5 s instead of cutting off.
            for step in stride(from: 10, through: 0, by: -1) {
                self.player.volume = Float(step) / 10
                try? await Task.sleep(for: .milliseconds(500))
            }
            self.pause()
            self.player.volume = 1
            self.sleepEndsAt = nil
        }
    }

    // MARK: - Item lifecycle

    private func startCandidate() {
        generation += 1
        let gen = generation
        tearDownItem()
        watchdog?.cancel()

        guard candidateIndex < candidates.count else {
            fail("Every available source for this channel failed.")
            return
        }
        let ep = candidates[candidateIndex]
        var headers: [String: String] = [:]
        if let ua = ep.userAgent { headers["User-Agent"] = ua }
        if let r = ep.referer { headers["Referer"] = r }
        let asset = AVURLAsset(url: ep.url, options: headers.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": headers])
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = AppModel.shared.user.settings.forwardBufferSeconds
        item.preferredPeakBitRate = audioOnly ? 400_000 : 0
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = false

        itemObservers.append(item.observe(\.status, options: [.new]) { [weak self] it, _ in
            let st = it.status
            let err = it.error?.localizedDescription
            Task { @MainActor in self?.itemStatus(st, error: err, generation: gen) }
        })
        for name in [AVPlayerItem.failedToPlayToEndTimeNotification, AVPlayerItem.playbackStalledNotification] {
            itemTokens.append(NotificationCenter.default.addObserver(forName: name, object: item, queue: .main) { [weak self] n in
                let stalled = n.name == AVPlayerItem.playbackStalledNotification
                Task { @MainActor in self?.itemTrouble(stalled: stalled, generation: gen) }
            })
        }
        itemTokens.append(NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.itemEnded(generation: gen) }
        })

        status = .loading
        wantsPlay = true
        try? AVAudioSession.sharedInstance().setActive(true)
        player.replaceCurrentItem(with: item)
        player.play()
        updateNowPlaying()
        updateRemoteCommandAvailability()

        // A stream that neither plays nor errors (dead host, endless redirect) must not hang the UI.
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(14))
            guard !Task.isCancelled, let self, gen == self.generation, self.status == .loading else { return }
            self.failover(reason: "timed out")
        }
    }

    private func itemStatus(_ s: AVPlayerItem.Status, error: String?, generation gen: Int) {
        guard gen == generation else { return }
        switch s {
        case .failed: failover(reason: error ?? "stream error")
        case .readyToPlay:
            if resumeAt > 1, vod != nil {
                player.seek(to: CMTime(seconds: resumeAt, preferredTimescale: 600))
                resumeAt = 0
            }
            if vod != nil { installTimeObserver() }
        default: break
        }
    }

    private func itemTrouble(stalled: Bool, generation gen: Int) {
        guard gen == generation, isLive || candidates.count > 1 else { return }
        if stalled {
            // Live streams stall briefly all the time; only fail over if it doesn't recover.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                guard let self, gen == self.generation, self.player.timeControlStatus != .playing else { return }
                self.failover(reason: "stalled")
            }
        } else {
            failover(reason: "playback failed")
        }
    }

    private func itemEnded(generation gen: Int) {
        guard gen == generation else { return }
        if let v = vod {
            AppModel.shared.setProgress(v.id, position: 1, duration: 1, title: v.title, poster: v.poster, url: v.endpoint.url) // fraction 1 = finished
            if let next = vodQueue.first {
                play(next, queue: Array(vodQueue.dropFirst()))
            } else {
                status = .paused
            }
        } else if isLive {
            // A live stream that "ends" is a dropped connection.
            failover(reason: "stream ended")
        }
    }

    private func failover(reason: String) {
        guard candidateIndex + 1 < candidates.count else {
            fail("This channel isn't responding (\(reason)). It may be offline or need a different playlist URL.")
            return
        }
        candidateIndex += 1
        failoverNote = "Switched to backup source \(candidateIndex + 1) of \(candidates.count)"
        startCandidate()
    }

    private func fail(_ message: String) {
        generation += 1
        watchdog?.cancel()
        player.pause()
        status = .failed(message)
        isBuffering = false
        updateNowPlaying()
    }

    private func timeControlChanged(_ s: AVPlayer.TimeControlStatus) {
        switch s {
        case .playing:
            status = .playing
            isBuffering = false
            watchdog?.cancel()
            if candidateIndex == 0 { failoverNote = nil }
        case .waitingToPlayAtSpecifiedRate:
            isBuffering = true
        case .paused:
            // While we're (re)loading a stream AVPlayer briefly reports paused; only believe it if the user paused.
            if !wantsPlay, status != .idle, !isFailed { status = .paused }
        @unknown default: break
        }
        updateNowPlaying()
    }

    private func tearDownItem() {
        itemObservers.forEach { $0.invalidate() }
        itemObservers.removeAll()
        for t in itemTokens { NotificationCenter.default.removeObserver(t) }
        itemTokens.removeAll()
    }

    // MARK: - VOD progress

    private func installTimeObserver() {
        guard timeObserver == nil else { return }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 10, preferredTimescale: 1), queue: .main) { [weak self] _ in
            Task { @MainActor in self?.saveVODProgress(final: false) }
        }
    }

    private func removeTimeObserver() {
        if let t = timeObserver { player.removeTimeObserver(t); timeObserver = nil }
    }

    private func saveVODProgress(final: Bool) {
        guard let v = vod, let item = player.currentItem else { return }
        let d = item.duration.seconds
        let p = player.currentTime().seconds
        guard d.isFinite, d > 0, p.isFinite else { return }
        AppModel.shared.setProgress(v.id, position: p, duration: d, title: v.title, poster: v.poster, url: v.endpoint.url)
    }

    // MARK: - Now playing & remote commands

    private func startMetaTimer() {
        metaTask?.cancel()
        metaTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                self?.updateNowPlaying()
            }
        }
    }

    private func loadArtwork(_ url: URL?) {
        artwork = nil
        guard let url else { return }
        Task { [weak self] in
            guard let img = await ImageLoader.shared.image(url, maxPixel: 600) else { return }
            await MainActor.run {
                self?.artwork = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
                self?.updateNowPlaying()
            }
        }
    }

    func updateNowPlaying() {
        guard hasMedia else { return }
        var info: [String: Any] = [MPMediaItemPropertyTitle: title]
        if let ch = channel {
            let nn = AppModel.shared.nowNext(ch)
            info[MPMediaItemPropertyArtist] = nn.now?.title ?? ch.group
            info[MPMediaItemPropertyAlbumTitle] = nn.next.map { "Next: \($0.title)" } ?? ""
            info[MPNowPlayingInfoPropertyIsLiveStream] = true
        } else if let item = player.currentItem {
            let d = item.duration.seconds
            if d.isFinite { info[MPMediaItemPropertyPlaybackDuration] = d }
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = player.currentTime().seconds
        }
        info[MPNowPlayingInfoPropertyPlaybackRate] = player.rate
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func configureRemoteCommands() {
        let cc = MPRemoteCommandCenter.shared()
        cc.playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.resume() }; return .success }
        cc.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.pause() }; return .success }
        cc.togglePlayPauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.togglePlayPause() }; return .success }
        cc.nextTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.zap(1) }; return .success }
        cc.previousTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.zap(-1) }; return .success }
        cc.skipForwardCommand.preferredIntervals = [30]
        cc.skipBackwardCommand.preferredIntervals = [15]
        cc.skipForwardCommand.addTarget { [weak self] _ in Task { @MainActor in self?.seek(by: 30) }; return .success }
        cc.skipBackwardCommand.addTarget { [weak self] _ in Task { @MainActor in self?.seek(by: -15) }; return .success }
        cc.changePlaybackPositionCommand.addTarget { [weak self] e in
            guard let e = e as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.player.seek(to: CMTime(seconds: e.positionTime, preferredTimescale: 600)) }
            return .success
        }
        updateRemoteCommandAvailability()
    }

    private func updateRemoteCommandAvailability() {
        let cc = MPRemoteCommandCenter.shared()
        let live = isLive
        cc.nextTrackCommand.isEnabled = live && zapList.count > 1
        cc.previousTrackCommand.isEnabled = live && zapList.count > 1
        cc.skipForwardCommand.isEnabled = !live
        cc.skipBackwardCommand.isEnabled = !live
        cc.changePlaybackPositionCommand.isEnabled = !live
    }
}
