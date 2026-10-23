import CarPlay
import UIKit
import LuminaCore

/// CarPlay entry point. Declared in Info.plist (`CPTemplateApplicationSceneSessionRoleApplication`).
/// Runs in the same process as the phone UI, so it shares `AppModel` and the single `PlayerController`.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var controller: CarPlayController?

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        let c = MainActor.assumeIsolated { CarPlayController(interfaceController: interfaceController) }
        controller = c
        MainActor.assumeIsolated { c.start() }
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        MainActor.assumeIsolated { controller?.stop() }
        controller = nil
    }
}

/// Keep CarPlay lean: no per-frame work, templates are updated in place (never rebuilt while driving),
/// artwork is tiny and loaded lazily, lists are capped.
@MainActor
final class CarPlayController: NSObject, CPSearchTemplateDelegate {
    private let ic: CPInterfaceController
    private var tabBar: CPTabBarTemplate?
    private var favoritesTemplate: CPListTemplate?
    private var recentTemplate: CPListTemplate?
    private var browseTemplate: CPListTemplate?
    private var liveItems: [(item: CPListItem, channel: Channel)] = []
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var pendingRebuild: Task<Void, Never>?

    private var model: AppModel { AppModel.shared }
    private var player: PlayerController { PlayerController.shared }
    private var limit: Int { max(10, min(model.user.settings.carPlayMaxItems, 200)) }

    init(interfaceController: CPInterfaceController) {
        ic = interfaceController
        super.init()
    }

    // MARK: Lifecycle

    func start() {
        player.configureIfNeeded()

        let fav = makeChannelTemplate(title: "Favorites", icon: "star.fill", channels: model.favoriteChannels,
                                      empty: "Star channels on your iPhone and they show up here.")
        let rec = makeChannelTemplate(title: "Recent", icon: "clock.fill", channels: model.recentChannels,
                                      empty: "Channels you watch will appear here.")
        let browse = CPListTemplate(title: "Browse", sections: browseSections())
        browse.tabTitle = "Browse"
        browse.tabImage = UIImage(systemName: "square.grid.2x2.fill")
        favoritesTemplate = fav
        recentTemplate = rec
        browseTemplate = browse

        let tb = CPTabBarTemplate(templates: [fav, rec, browse])
        tabBar = tb
        ic.setRootTemplate(tb, animated: false, completion: nil)

        // Data may still be loading if the car connected before the phone UI ever launched.
        Task {
            await model.bootstrap()
            self.scheduleRebuild()
        }
        observers.append(NotificationCenter.default.addObserver(forName: .luminaLibraryChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.scheduleRebuild() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .luminaGuideChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshLiveItems() }
        })
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshLiveItems() }
        }
        updateNowPlayingButtons()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers.removeAll()
        pendingRebuild?.cancel()
        liveItems.removeAll()
        // The car is gone: don't keep paying for video bandwidth we can no longer show.
        player.setAudioOnly(false)
    }

    /// Coalesces bursts of library/guide updates into one in-place refresh.
    private func scheduleRebuild() {
        pendingRebuild?.cancel()
        pendingRebuild = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self.rebuild()
        }
    }

    private func rebuild() {
        liveItems.removeAll()
        favoritesTemplate?.updateSections([CPListSection(items: items(for: model.favoriteChannels))])
        recentTemplate?.updateSections([CPListSection(items: items(for: model.recentChannels))])
        browseTemplate?.updateSections(browseSections())
    }

    // MARK: Templates

    private func makeChannelTemplate(title: String, icon: String, channels: [Channel], empty: String) -> CPListTemplate {
        let t = CPListTemplate(title: title, sections: [CPListSection(items: items(for: channels))])
        t.tabTitle = title
        t.tabImage = UIImage(systemName: icon)
        t.emptyViewSubtitleVariants = [empty]
        return t
    }

    private func items(for channels: [Channel]) -> [CPListItem] {
        let shown = Array(channels.prefix(limit))
        return shown.map { item(for: $0, in: shown) }
    }

    private func item(for channel: Channel, in list: [Channel]) -> CPListItem {
        let nn = model.nowNext(channel)
        let placeholder = UIImage(systemName: "tv")
        let it = CPListItem(text: channel.name, detailText: nn.now?.title ?? GroupLabel.parse(channel.group).title, image: placeholder)
        if let p = nn.now { it.playbackProgress = CGFloat(p.progress(at: Date())) }
        it.isPlaying = isCurrent(channel)
        it.handler = { [weak self] _, done in
            Task { @MainActor in self?.play(channel, in: list) }
            done()
        }
        if let url = channel.logo {
            Task {
                if let img = await ImageLoader.shared.image(url, maxPixel: 120) { it.setImage(img) }
            }
        }
        liveItems.append((it, channel))
        if liveItems.count > 600 { liveItems.removeFirst(liveItems.count - 600) }
        return it
    }

    private func browseSections() -> [CPListSection] {
        let search = CPListItem(text: "Search channels", detailText: "Say or type a name", image: UIImage(systemName: "magnifyingglass"))
        search.accessoryType = .disclosureIndicator
        search.handler = { [weak self] _, done in
            Task { @MainActor in self?.openSearch() }
            done()
        }
        let groupItems: [CPListItem] = model.browseGroups.prefix(limit).map { g in
            let it = CPListItem(text: g.label.title, detailText: "\(g.count) channels")
            it.accessoryType = .disclosureIndicator
            it.handler = { [weak self] _, done in
                Task { @MainActor in self?.openGroup(g) }
                done()
            }
            return it
        }
        return [CPListSection(items: [search]), CPListSection(items: groupItems, header: "Groups", sectionIndexTitle: nil)]
    }

    private func openGroup(_ g: GroupInfo) {
        if model.isLocked(group: g.id) {
            alert("This group is locked", "Unlock it on your iPhone first.")
            return
        }
        let t = makeChannelTemplate(title: g.label.title, icon: "tv", channels: model.channels(in: g.id), empty: "No channels in this group.")
        ic.pushTemplate(t, animated: true, completion: nil)
    }

    private func openSearch() {
        let s = CPSearchTemplate()
        s.delegate = self
        ic.pushTemplate(s, animated: true, completion: nil)
    }

    // MARK: Playback

    private func isCurrent(_ c: Channel) -> Bool { player.hasMedia && player.channel?.id == c.id }

    private func play(_ channel: Channel, in list: [Channel]) {
        if model.isLocked(group: channel.group) {
            alert("This channel is locked", "Unlock its group on your iPhone first.")
            return
        }
        player.setAudioOnly(model.user.settings.carPlayAudioOnly)
        player.play(channel, in: list)
        updateNowPlayingButtons()
        refreshLiveItems()
        if ic.topTemplate !== CPNowPlayingTemplate.shared {
            ic.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
        }
    }

    private func updateNowPlayingButtons() {
        let isFav = player.channel.map { model.isFavorite($0) } ?? false
        let name = isFav ? "star.fill" : "star"
        guard let img = UIImage(systemName: name) else { return }
        let fav = CPNowPlayingImageButton(image: img) { [weak self] _ in
            Task { @MainActor in
                guard let self, let ch = self.player.channel else { return }
                self.model.toggleFavorite(ch)
                self.updateNowPlayingButtons()
                self.scheduleRebuild()
            }
        }
        CPNowPlayingTemplate.shared.updateNowPlayingButtons([fav])
    }

    private func refreshLiveItems() {
        let now = Date()
        for (item, ch) in liveItems {
            let nn = model.nowNext(ch, at: now)
            item.setDetailText(nn.now?.title ?? GroupLabel.parse(ch.group).title)
            item.playbackProgress = CGFloat(nn.now?.progress(at: now) ?? 0)
            item.isPlaying = isCurrent(ch)
        }
        updateNowPlayingButtons()
    }

    private func alert(_ title: String, _ detail: String) {
        let ok = CPAlertAction(title: "OK", style: .default) { [weak self] _ in
            self?.ic.dismissTemplate(animated: true, completion: nil)
        }
        ic.presentTemplate(CPAlertTemplate(titleVariants: [title, detail], actions: [ok]), animated: true, completion: nil)
    }

    // MARK: CPSearchTemplateDelegate

    nonisolated func searchTemplate(
        _ searchTemplate: CPSearchTemplate, updatedSearchText searchText: String,
        completionHandler: @escaping ([CPListItem]) -> Void
    ) {
        Task { @MainActor in
            let found = Array(self.model.search(searchText).channels.prefix(12))
            completionHandler(found.map { ch in
                let it = CPListItem(text: ch.name, detailText: self.model.nowNext(ch).now?.title ?? GroupLabel.parse(ch.group).title,
                                    image: UIImage(systemName: "tv"))
                it.userInfo = ch.id
                if let url = ch.logo {
                    Task { if let img = await ImageLoader.shared.image(url, maxPixel: 120) { it.setImage(img) } }
                }
                return it
            })
        }
    }

    nonisolated func searchTemplate(
        _ searchTemplate: CPSearchTemplate, selectedResult item: CPListItem, completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in
            if let id = item.userInfo as? String, let ch = self.model.channel(id: id) {
                self.play(ch, in: [ch])
            }
            completionHandler()
        }
    }
}
