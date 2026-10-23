import Foundation
import Observation
import SwiftUI
import LuminaCore

extension Notification.Name {
    static let luminaLibraryChanged = Notification.Name("lumina.library.changed")
    static let luminaGuideChanged = Notification.Name("lumina.guide.changed")
}

struct GroupInfo: Identifiable, Hashable, Sendable {
    let id: String // raw group name from the provider
    let label: GroupLabel
    var count: Int
    let adultLooking: Bool
}

struct PlayableVOD: Identifiable, Hashable {
    let id: String
    let title: String
    let endpoint: StreamEndpoint
    let poster: URL?
}

/// Single source of truth shared by the phone UI and the CarPlay scene (same process).
@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    enum LoadState: Equatable {
        case idle
        case loading(String)
    }

    // MARK: Observable state

    private(set) var sources: [Source] = []
    private(set) var user = UserData()
    private(set) var visibleChannels: [Channel] = []
    private(set) var channelsByGroup: [String: [Channel]] = [:]
    private(set) var browseGroups: [GroupInfo] = []   // groups that have at least one visible channel
    private(set) var allGroups: [GroupInfo] = []
    private(set) var movies: [VODItem] = []
    private(set) var series: [Series] = []
    private(set) var accounts: [UUID: XtreamAccount] = [:]
    private(set) var loadState: LoadState = .idle
    private(set) var lastError: String?
    private(set) var libraryVersion = 0
    private(set) var guideVersion = 0
    private(set) var booted = false
    private(set) var guideUpdatedAt: Date?
    private(set) var deadChannels: Set<String> = []
    private(set) var scanProgress: (done: Int, total: Int)?

    var unlockedGroups: Set<String> = []

    // MARK: Internals (not observed)

    @ObservationIgnored private(set) var epg = EPGIndex()
    @ObservationIgnored private var snapshots: [UUID: SourceSnapshot] = [:]
    @ObservationIgnored private var allChannels: [Channel] = []
    @ObservationIgnored private var channelByID: [String: Channel] = [:]
    @ObservationIgnored private var visibleIDs: Set<String> = []
    @ObservationIgnored private var guideKeys: [String: String] = [:]
    @ObservationIgnored private var keyToChannels: [String: [Channel]] = [:]
    @ObservationIgnored private var searchIndex = SearchIndex(channels: [], movies: [], series: [])
    @ObservationIgnored private var episodesBySeries: [String: [Episode]] = [:]
    @ObservationIgnored private var fetchedEpisodes: [String: [Episode]] = [:]
    @ObservationIgnored private var offsets: [UUID: TimeInterval] = [:]
    @ObservationIgnored private let loader = PlaylistLoader()
    @ObservationIgnored private var userSaveTask: Task<Void, Never>?
    @ObservationIgnored private var guideTask: Task<Void, Never>?
    @ObservationIgnored private var scanTask: Task<Void, Never>?

    private init() {}

    // MARK: - Boot

    func bootstrap() async {
        guard !booted else { return }
        booted = true
        sources = JSONFile.read([Source].self, from: AppPaths.sources) ?? []
        user = JSONFile.read(UserData.self, from: AppPaths.user) ?? UserData()
        offsets = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, TimeInterval($0.epgOffsetMinutes * 60)) })

        let ids = sources.filter(\.enabled).map(\.id)
        let loaded: [SourceSnapshot] = await Task.detached(priority: .userInitiated) {
            ids.compactMap { JSONFile.read(SourceSnapshot.self, from: AppPaths.snapshot($0)) }
        }.value
        for s in loaded {
            snapshots[s.sourceID] = s
            accounts[s.sourceID] = s.account
        }
        await rebuild()
        await refreshGuide(force: false)      // cached guide first: instant now/next
        await refreshStaleSources()
    }

    // MARK: - Sources

    func addSource(_ source: Source) async throws {
        loadState = .loading("Connecting to \(source.name)…")
        defer { loadState = .idle }
        let snap = try await loader.load(resolved(source))
        var s = source
        s.lastRefreshed = Date()
        sources.append(s)
        snapshots[s.id] = snap
        accounts[s.id] = snap.account
        offsets[s.id] = TimeInterval(s.epgOffsetMinutes * 60)
        saveSources()
        persist(snap)
        await rebuild()
        Task { await refreshGuide(force: true) }
    }

    func updateSource(_ source: Source) {
        guard let i = sources.firstIndex(where: { $0.id == source.id }) else { return }
        sources[i] = source
        offsets[source.id] = TimeInterval(source.epgOffsetMinutes * 60)
        saveSources()
        Task { await rebuild(); bumpGuide() }
    }

    func removeSource(_ id: UUID) {
        sources.removeAll { $0.id == id }
        snapshots[id] = nil
        accounts[id] = nil
        try? FileManager.default.removeItem(at: AppPaths.snapshot(id))
        saveSources()
        Task { await rebuild() }
    }

    func refresh(_ id: UUID) async {
        guard let i = sources.firstIndex(where: { $0.id == id }) else { return }
        loadState = .loading("Updating \(sources[i].name)…")
        defer { loadState = .idle }
        do {
            let snap = try await loader.load(resolved(sources[i]))
            sources[i].lastRefreshed = Date()
            snapshots[id] = snap
            accounts[id] = snap.account
            saveSources()
            persist(snap)
            await rebuild()
            lastError = nil
        } catch {
            lastError = "\(sources[i].name): \(error.localizedDescription)"
        }
    }

    func refreshAll() async {
        for s in sources where s.enabled { await refresh(s.id) }
        await refreshGuide(force: true)
    }

    private func refreshStaleSources() async {
        let maxAge = TimeInterval(max(1, user.settings.guideRefreshHours)) * 3600
        for s in sources where s.enabled && s.kindNeedsNetwork {
            if let t = s.lastRefreshed, Date().timeIntervalSince(t) < maxAge { continue }
            await refresh(s.id)
        }
        await refreshGuide(force: false)
    }

    /// Copies a user-picked playlist into our container so it survives the picker's security scope.
    func importPlaylistFile(_ url: URL) throws -> Source {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let name = "\(UUID().uuidString.prefix(8))-\(url.lastPathComponent)"
        let dst = AppPaths.imports.appendingPathComponent(name)
        try FileManager.default.copyItem(at: url, to: dst)
        return Source(name: url.deletingPathExtension().lastPathComponent, kind: .m3u(dst))
    }

    /// "Open in Lumina" from Files / Safari / AirDrop for .m3u and .m3u8 files.
    func handleOpen(_ url: URL) async {
        guard url.isFileURL else { return }
        do {
            let src = try importPlaylistFile(url)
            try await addSource(src)
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func addDemo() async {
        guard !sources.contains(where: { $0.kind == .demo }) else { return }
        try? await addSource(Source(name: "Demo", kind: .demo))
    }

    private func resolved(_ s: Source) -> Source {
        guard case .m3u(let u) = s.kind, u.isFileURL else { return s }
        var c = s
        c.kind = .m3u(AppPaths.resolveImport(u))
        return c
    }

    private func saveSources() {
        let s = sources
        Task.detached { try? JSONFile.write(s, to: AppPaths.sources) }
    }

    private func persist(_ snap: SourceSnapshot) {
        Task.detached(priority: .utility) { try? JSONFile.write(snap, to: AppPaths.snapshot(snap.sourceID)) }
    }

    // MARK: - Derived library

    private struct Derived: Sendable {
        var channels: [Channel]
        var aliases: [String: String]
        var groups: [GroupInfo]
        var movies: [VODItem]
        var series: [Series]
        var episodes: [String: [Episode]]
        var search: SearchIndex
    }

    nonisolated private static func derive(snaps: [SourceSnapshot], order: [UUID], merge: Bool) -> Derived {
        let sorted = snaps.sorted { (order.firstIndex(of: $0.sourceID) ?? 0) < (order.firstIndex(of: $1.sourceID) ?? 0) }
        var channels = sorted.flatMap(\.channels)
        var aliases: [String: String] = [:]
        if merge {
            let r = ChannelMerger.mergeDuplicates(channels)
            channels = r.channels
            aliases = r.aliases
        }
        var counts: [String: Int] = [:]
        var order: [String] = []
        for c in channels {
            if counts[c.group] == nil { order.append(c.group) }
            counts[c.group, default: 0] += 1
        }
        let groups = order.map {
            GroupInfo(id: $0, label: GroupLabel.parse($0), count: counts[$0] ?? 0, adultLooking: ParentalHeuristics.looksAdult(group: $0))
        }
        let movies = sorted.flatMap(\.movies)
        let series = sorted.flatMap(\.series)
        return Derived(
            channels: channels, aliases: aliases, groups: groups, movies: movies, series: series,
            episodes: Dictionary(grouping: sorted.flatMap(\.episodes), by: \.seriesID),
            search: SearchIndex(channels: channels, movies: movies, series: series)
        )
    }

    func rebuild() async {
        let enabled = Set(sources.filter(\.enabled).map(\.id))
        let snaps = snapshots.values.filter { enabled.contains($0.sourceID) }
        let order = sources.map(\.id)
        let merge = user.settings.mergeDuplicates
        let d = await Task.detached(priority: .userInitiated) {
            Self.derive(snaps: Array(snaps), order: order, merge: merge)
        }.value

        allChannels = d.channels
        channelByID = Dictionary(d.channels.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        allGroups = d.groups
        movies = d.movies
        series = d.series
        episodesBySeries = d.episodes
        searchIndex = d.search
        if !d.aliases.isEmpty {
            var u = user
            u.applyAliases(d.aliases)
            if u != user { user = u; saveUserSoon() }
        }
        recomputeVisibility()
        libraryVersion += 1
        await computeGuideKeys()
        NotificationCenter.default.post(name: .luminaLibraryChanged, object: nil)
    }

    private func recomputeVisibility() {
        let hidden = user.hiddenChannels
        let hiddenGroups = user.hiddenGroups
        let adult: Set<String> = user.settings.hideAdultByDefault ? Set(allGroups.filter(\.adultLooking).map(\.id)) : []
        let visible = allChannels.filter {
            !hidden.contains($0.id) && !hiddenGroups.contains($0.group) && !adult.contains($0.group) && !deadChannels.contains($0.id)
        }
        visibleChannels = visible
        visibleIDs = Set(visible.map(\.id))
        channelsByGroup = Dictionary(grouping: visible, by: \.group)
        browseGroups = allGroups.compactMap { g in
            guard let n = channelsByGroup[g.id]?.count else { return nil }
            var c = g
            c.count = n
            return c
        }
    }

    // MARK: - Lookups

    func channel(id: String) -> Channel? { channelByID[id] }
    var favoriteChannels: [Channel] { user.favorites.compactMap { channelByID[$0] }.filter { visibleIDs.contains($0.id) } }
    var recentChannels: [Channel] { user.recents.compactMap { channelByID[$0] }.filter { visibleIDs.contains($0.id) } }
    var lastChannel: Channel? { user.lastChannelID.flatMap { channelByID[$0] } }
    func channels(in group: String) -> [Channel] { channelsByGroup[group] ?? [] }

    func isLocked(group: String) -> Bool {
        user.hasPIN && user.lockedGroups.contains(group) && !unlockedGroups.contains(group)
    }

    func unlock(group: String, pin: String) -> Bool {
        guard user.verifyPIN(pin) else { return false }
        unlockedGroups.insert(group)
        return true
    }

    func lockAll() { unlockedGroups.removeAll() }

    var hasSources: Bool { !sources.isEmpty }

    // MARK: - Guide

    func epgOffset(for channel: Channel) -> TimeInterval { offsets[channel.sourceID] ?? 0 }

    /// Programmes come back already shifted by the source's guide offset, so callers can compare with real time.
    func nowNext(_ c: Channel, at date: Date = Date()) -> (now: Programme?, next: Programme?) {
        guard let k = guideKeys[c.id] else { return (nil, nil) }
        let off = offsets[c.sourceID] ?? 0
        let r = epg.nowNext(forKey: k, at: date, offset: off)
        guard off != 0 else { return r }
        func shift(_ p: Programme?) -> Programme? {
            guard var q = p else { return nil }
            q.start = q.start.addingTimeInterval(off)
            q.stop = q.stop.addingTimeInterval(off)
            return q
        }
        return (shift(r.now), shift(r.next))
    }

    /// Programmes for the day view, already shifted by the source's guide offset.
    func schedule(for c: Channel, from: Date, to: Date) -> [Programme] {
        guard let k = guideKeys[c.id] else { return [] }
        let off = offsets[c.sourceID] ?? 0
        return epg.programmes(forKey: k)
            .filter { $0.stop.addingTimeInterval(off) > from && $0.start.addingTimeInterval(off) < to }
            .map { p in
                var q = p
                q.start = p.start.addingTimeInterval(off)
                q.stop = p.stop.addingTimeInterval(off)
                return q
            }
    }

    private func bumpGuide() {
        guideVersion += 1
        NotificationCenter.default.post(name: .luminaGuideChanged, object: nil)
    }

    private func computeGuideKeys() async {
        let chans = allChannels
        let idx = epg
        let (keys, rev) = await Task.detached(priority: .utility) { () -> ([String: String], [String: [Channel]]) in
            var m: [String: String] = [:]
            var r: [String: [Channel]] = [:]
            for c in chans {
                if let k = idx.guideKey(for: c) {
                    m[c.id] = k
                    r[k, default: []].append(c)
                }
            }
            return (m, r)
        }.value
        guideKeys = keys
        keyToChannels = rev
        bumpGuide()
    }

    func refreshGuide(force: Bool) async {
        if let t = guideTask { await t.value; if !force { return } }
        let task = Task { await self.loadGuide(force: force) }
        guideTask = task
        await task.value
        guideTask = nil
    }

    private func loadGuide(force: Bool) async {
        let maxAge = TimeInterval(max(1, user.settings.guideRefreshHours)) * 3600
        var urls: [URL] = []
        var seen = Set<URL>()
        var ua: String?
        for s in sources where s.enabled {
            ua = ua ?? s.userAgent
            for u in snapshots[s.id]?.epgURLs ?? [] where seen.insert(u).inserted { urls.append(u) }
        }
        let hasDemo = sources.contains { $0.kind == .demo && $0.enabled }

        // 1. Cached guide.
        if !force, epg.isEmpty,
           let cache = await Task.detached(priority: .userInitiated, operation: { JSONFile.read(GuideCache.self, from: AppPaths.guide) }).value {
            var idx = await Task.detached { cache.index }.value
            if hasDemo { idx.merge(DemoContent.guide()) }
            epg = idx
            guideUpdatedAt = cache.fetchedAt
            await computeGuideKeys()
            if Date().timeIntervalSince(cache.fetchedAt) < maxAge { return }
        } else if hasDemo, epg.isEmpty {
            epg = DemoContent.guide()
            await computeGuideKeys()
        }
        guard !urls.isEmpty else { return }
        if !force, let t = guideUpdatedAt, Date().timeIntervalSince(t) < maxAge { return }

        // 2. Download + parse in the background, restricted to channels we actually have.
        let channels = allChannels
        let wantedIDs = Set(channels.compactMap { $0.epgID?.lowercased() })
        var nameKeys = Set(channels.map { NameNormalizer.key($0.name) })
        for c in channels { if let e = c.epgID { nameKeys.insert(NameNormalizer.key(e)) } }
        let now = Date()
        let maxCatchup = channels.compactMap { $0.catchup?.days }.max() ?? 0
        let window = now.addingTimeInterval(-Double(max(1, min(maxCatchup, 3))) * 86_400)...now.addingTimeInterval(2 * 86_400)
        let loader = self.loader

        var merged = EPGIndex()
        var combined = XMLTVResult()
        var failures = 0
        for url in urls {
            do {
                let r = try await loader.loadGuide(url, userAgent: ua, wantedIDs: wantedIDs, wantedNameKeys: nameKeys, window: window)
                combined.programmes += r.programmes
                combined.channelNames.merge(r.channelNames) { a, _ in a }
                combined.channelIcons.merge(r.channelIcons) { a, _ in a }
            } catch {
                failures += 1
            }
        }
        if combined.programmes.isEmpty {
            if failures > 0, epg.isEmpty { lastError = "The TV guide couldn't be loaded. Channels still play; check the guide URL in Settings." }
            return
        }
        let result = combined
        merged = await Task.detached(priority: .utility) { result.index }.value
        if hasDemo { merged.merge(DemoContent.guide()) }
        epg = merged
        guideUpdatedAt = Date()
        await computeGuideKeys()
        Task.detached(priority: .background) { try? JSONFile.write(GuideCache(from: result), to: AppPaths.guide) }
    }

    /// Panels without an XMLTV feed still answer per-channel guide requests.
    func ensureGuide(for c: Channel) async {
        guard guideKeys[c.id] == nil,
              let src = sources.first(where: { $0.id == c.sourceID }),
              case .xtream(let server, let u, let p) = src.kind,
              let last = c.id.split(separator: ":").last, last.hasPrefix("x") else { return }
        let client = XtreamClient(server: server, username: u, password: p)
        guard let progs = try? await client.fullDayEPG(streamID: String(last.dropFirst()), guideChannel: c.id.lowercased()),
              !progs.isEmpty else { return }
        var idx = epg
        idx.merge(EPGIndex(programmes: progs))
        epg = idx
        guideKeys[c.id] = c.id.lowercased()
        bumpGuide()
    }

    // MARK: - Search

    func search(_ q: String) -> SearchResults {
        var r = searchIndex.search(q, limit: 40)
        r.channels = r.channels.filter { visibleIDs.contains($0.id) }
        return r
    }

    func programmeSearch(_ q: String) -> [(Programme, Channel)] {
        let now = Date()
        return epg.search(q, from: now, to: now.addingTimeInterval(36 * 3600), limit: 30).compactMap { p in
            guard let c = keyToChannels[p.channel]?.first(where: { visibleIDs.contains($0.id) }) else { return nil }
            return (p, c)
        }
    }

    // MARK: - User data

    func updateUser(_ change: (inout UserData) -> Void) {
        var u = user
        change(&u)
        guard u != user else { return }
        let visibilityChanged = u.hiddenChannels != user.hiddenChannels || u.hiddenGroups != user.hiddenGroups
            || u.settings.hideAdultByDefault != user.settings.hideAdultByDefault
        let mergeChanged = u.settings.mergeDuplicates != user.settings.mergeDuplicates
        user = u
        saveUserSoon()
        if mergeChanged { Task { await rebuild() } } else if visibilityChanged { recomputeVisibility(); libraryVersion += 1 }
    }

    func binding<T>(_ kp: WritableKeyPath<UserData, T>) -> Binding<T> {
        Binding(get: { self.user[keyPath: kp] }, set: { v in self.updateUser { $0[keyPath: kp] = v } })
    }

    private func saveUserSoon() {
        userSaveTask?.cancel()
        userSaveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            let u = user
            await Task.detached { try? JSONFile.write(u, to: AppPaths.user) }.value
        }
    }

    func toggleFavorite(_ c: Channel) { updateUser { $0.toggleFavorite(c.id) } }
    func isFavorite(_ c: Channel) -> Bool { user.isFavorite(c.id) }
    func noteWatched(_ c: Channel) { updateUser { $0.pushRecent(c.id) } }

    func setProgress(_ id: String, position: TimeInterval, duration: TimeInterval, title: String, poster: URL?, url: URL?) {
        guard duration > 0 else { return }
        updateUser { $0.setProgress(id, WatchProgress(position: position, duration: duration, title: title, poster: poster, streamURL: url)) }
    }

    struct ContinueItem: Identifiable {
        let id: String
        let progress: WatchProgress
    }

    var continueWatching: [ContinueItem] {
        user.progress.filter { !$0.value.isFinished && $0.value.position > 20 }
            .sorted { $0.value.updated > $1.value.updated }
            .prefix(20).map { ContinueItem(id: $0.key, progress: $0.value) }
    }

    // MARK: - Hide / dead-channel scan

    func hide(_ c: Channel) { updateUser { $0.hiddenChannels.insert(c.id) } }
    func unhideAll() { updateUser { $0.hiddenChannels.removeAll(); $0.hiddenGroups.removeAll() }; deadChannels.removeAll(); recomputeVisibility() }

    func scanForDeadChannels(limitTo group: String? = nil) {
        scanTask?.cancel()
        let list = group.map { channels(in: $0) } ?? visibleChannels
        scanProgress = (0, list.count)
        scanTask = Task {
            var done = 0
            var dead: [String] = []
            for await r in StreamHealth.scan(list, concurrency: 6) {
                done += 1
                if !r.alive { dead.append(r.channelID) }
                scanProgress = (done, list.count)
            }
            if !Task.isCancelled { deadChannels = Set(dead) }
            scanProgress = nil
        }
    }

    func cancelScan() { scanTask?.cancel(); scanProgress = nil }
    func applyDeadChannelHiding() { recomputeVisibility(); libraryVersion += 1 }

    // MARK: - VOD helpers

    func episodes(for s: Series) async -> [Episode] {
        if let e = episodesBySeries[s.id], !e.isEmpty { return e.sorted { ($0.season, $0.number) < ($1.season, $1.number) } }
        if let e = fetchedEpisodes[s.id] { return e }
        guard let xid = s.xtreamID, let src = sources.first(where: { $0.id == s.sourceID }),
              case .xtream(let server, let u, let p) = src.kind else { return [] }
        let client = XtreamClient(server: server, username: u, password: p)
        let eps = (try? await client.episodes(seriesID: xid, localSeriesID: s.id, userAgent: src.userAgent)) ?? []
        fetchedEpisodes[s.id] = eps
        return eps
    }

    func detail(for m: VODItem) async -> VODDetail? {
        guard let xid = m.xtreamID, let src = sources.first(where: { $0.id == m.sourceID }),
              case .xtream(let server, let u, let p) = src.kind else { return nil }
        return try? await XtreamClient(server: server, username: u, password: p).vodDetail(id: xid)
    }

    // MARK: - Backup

    struct Backup: Codable {
        var sources: [Source]
        var user: UserData
        var version = 1
    }

    func exportBackup() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Lumina-Backup.json")
        try JSONFile.write(Backup(sources: sources, user: user), to: url)
        return url
    }

    func importBackup(_ url: URL) async throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        let b = try JSONDecoder().decode(Backup.self, from: data)
        user = b.user
        saveUserSoon()
        for s in b.sources where !sources.contains(where: { $0.id == s.id }) {
            try? await addSource(s)
        }
        recomputeVisibility()
        libraryVersion += 1
    }
}

private extension Source {
    var kindNeedsNetwork: Bool {
        switch kind {
        case .demo: false
        case .m3u(let u): !u.isFileURL
        case .xtream: true
        }
    }
}
