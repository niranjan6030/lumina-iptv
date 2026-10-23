import SwiftUI
import LuminaCore

enum LiveFilter: Hashable {
    case favorites, recents, all
    case group(String)
}

struct LiveView: View {
    @Environment(AppModel.self) private var model
    @State private var chosen: LiveFilter?
    @State private var showGroups = false
    @State private var scheduleFor: Channel?

    private var filter: LiveFilter {
        if let chosen { return chosen }
        return model.favoriteChannels.isEmpty ? .all : .favorites
    }

    private var channels: [Channel] {
        switch filter {
        case .favorites: model.favoriteChannels
        case .recents: model.recentChannels
        case .all: model.visibleChannels
        case .group(let g): model.channels(in: g)
        }
    }

    private var title: String {
        switch filter {
        case .favorites: "Favorites"
        case .recents: "Recent"
        case .all: "All Channels"
        case .group(let g): GroupLabel.parse(g).title
        }
    }

    var body: some View {
        NavigationStack {
            let list = channels
            TimelineView(.periodic(from: .now, by: 60)) { ctx in
                Group {
                    if model.user.settings.gridLayout {
                        ChannelGrid(channels: list, now: ctx.date, header: header, scheduleFor: $scheduleFor)
                    } else {
                        ChannelList(channels: list, now: ctx.date, header: header, scheduleFor: $scheduleFor)
                    }
                }
            }
            .background(AppBackground())
            .overlay { if list.isEmpty { emptyState } }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        model.updateUser { $0.settings.gridLayout.toggle() }
                    } label: {
                        Image(systemName: model.user.settings.gridLayout ? "list.bullet" : "square.grid.2x2")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .sheet(isPresented: $showGroups) {
                GroupPicker { chosen = $0; showGroups = false }
                    .presentationDetents([.medium, .large])
                    .presentationBackground(.ultraThinMaterial)
            }
            .sheet(item: $scheduleFor) { ScheduleView(channel: $0) }
            .miniPlayerInset()
        }
        .refreshable { await model.refreshAll() }
    }

    // Quick filters: shortcuts first, then the group browser.
    private var header: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if !model.favoriteChannels.isEmpty {
                    chip("Favorites", "star.fill", .favorites)
                }
                if !model.recentChannels.isEmpty {
                    chip("Recent", "clock", .recents)
                }
                chip("All", "square.stack", .all)
                Button { showGroups = true } label: {
                    Chip(title: groupChipTitle, systemImage: "line.3.horizontal.decrease", selected: isGroup)
                }
                .buttonStyle(.plain)
                if let last = model.lastChannel, model.user.settings.resumeLastChannel {
                    Button { UIState.shared.play(last, in: channels) } label: {
                        Chip(title: "Resume \(last.name)", systemImage: "play.fill")
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private var isGroup: Bool { if case .group = filter { true } else { false } }
    private var groupChipTitle: String { isGroup ? title : "Groups" }

    private func chip(_ t: String, _ icon: String, _ f: LiveFilter) -> some View {
        Button { chosen = f } label: { Chip(title: t, systemImage: icon, selected: filter == f) }
            .buttonStyle(.plain)
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.loadState != .idle {
            ProgressView()
        } else {
            ContentUnavailableView(
                filter == .favorites ? "No favorites yet" : "Nothing here",
                systemImage: filter == .favorites ? "star" : "tv.slash",
                description: Text(filter == .favorites ? "Swipe a channel and tap the star." : "Pull down to refresh your playlist.")
            )
        }
    }
}

// MARK: - List

struct ChannelList<Header: View>: View {
    let channels: [Channel]
    let now: Date
    let header: Header
    @Binding var scheduleFor: Channel?

    var body: some View {
        List {
            header
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            ForEach(channels) { ch in
                ChannelRow(channel: ch, now: now, list: channels, scheduleFor: $scheduleFor)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
    }
}

struct ChannelRow: View {
    @Environment(AppModel.self) private var model
    let channel: Channel
    let now: Date
    let list: [Channel]
    @Binding var scheduleFor: Channel?

    var body: some View {
        let _ = model.guideVersion // re-render when guide data arrives
        let nn = model.nowNext(channel, at: now)
        let locked = model.isLocked(group: channel.group)
        Button { UIState.shared.play(channel, in: list) } label: {
            HStack(spacing: 12) {
                LogoView(url: channel.logo, size: 54)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        if let n = channel.number { Text("\(n)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary) }
                        Text(channel.name).font(.headline).lineLimit(1)
                        if let q = channel.primary?.quality.label { QualityBadge(text: q) }
                        if channel.hasCatchup { Image(systemName: "gobackward").font(.caption2).foregroundStyle(.tertiary) }
                    }
                    if let p = nn.now {
                        Text(p.title).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        ProgressView(value: p.progress(at: now)).tint(Theme.accent).scaleEffect(y: 0.6)
                    } else {
                        Text(GroupLabel.parse(channel.group).title).font(.subheadline).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if locked { Image(systemName: "lock.fill").foregroundStyle(.secondary) }
                else if model.isFavorite(channel) { Image(systemName: "star.fill").foregroundStyle(.yellow).font(.footnote) }
            }
            .padding(10)
            .rowCard()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button { model.toggleFavorite(channel) } label: {
                Label(model.isFavorite(channel) ? "Unfavorite" : "Favorite", systemImage: model.isFavorite(channel) ? "star.slash" : "star")
            }.tint(.yellow)
        }
        .swipeActions(edge: .trailing) {
            Button { scheduleFor = channel } label: { Label("Guide", systemImage: "calendar") }.tint(Theme.accent2)
            Button(role: .destructive) { model.hide(channel) } label: { Label("Hide", systemImage: "eye.slash") }
        }
        .contextMenu {
            Button { model.toggleFavorite(channel) } label: {
                Label(model.isFavorite(channel) ? "Remove favorite" : "Add to favorites", systemImage: "star")
            }
            Button { scheduleFor = channel } label: { Label("Show schedule", systemImage: "calendar") }
            Button(role: .destructive) { model.hide(channel) } label: { Label("Hide channel", systemImage: "eye.slash") }
        }
    }
}

// MARK: - Grid

struct ChannelGrid<Header: View>: View {
    @Environment(AppModel.self) private var model
    let channels: [Channel]
    let now: Date
    let header: Header
    @Binding var scheduleFor: Channel?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14, pinnedViews: []) {
                header
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    ForEach(channels) { ch in
                        let _ = model.guideVersion
                        let nn = model.nowNext(ch, at: now)
                        Button { UIState.shared.play(ch, in: channels) } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    LogoView(url: ch.logo, size: 44, corner: 10)
                                    Spacer()
                                    if model.isFavorite(ch) { Image(systemName: "star.fill").foregroundStyle(.yellow).font(.caption) }
                                }
                                Text(ch.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                                Text(nn.now?.title ?? GroupLabel.parse(ch.group).title)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                if let p = nn.now { ProgressView(value: p.progress(at: now)).tint(Theme.accent) }
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .rowCard(18)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button { model.toggleFavorite(ch) } label: { Label("Favorite", systemImage: "star") }
                            Button { scheduleFor = ch } label: { Label("Show schedule", systemImage: "calendar") }
                            Button(role: .destructive) { model.hide(ch) } label: { Label("Hide", systemImage: "eye.slash") }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }
}

// MARK: - Group picker

struct GroupPicker: View {
    @Environment(AppModel.self) private var model
    let onPick: (LiveFilter) -> Void
    @State private var query = ""
    @State private var region: String?

    private var regions: [String] {
        Array(Set(model.browseGroups.compactMap(\.label.region))).sorted()
    }

    private var groups: [GroupInfo] {
        model.browseGroups.filter { g in
            (region == nil || g.label.region == region)
                && (query.isEmpty || g.label.title.localizedCaseInsensitiveContains(query) || g.id.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if !regions.isEmpty && model.user.settings.showGroupRegions {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            Button { region = nil } label: { Chip(title: "All", selected: region == nil) }.buttonStyle(.plain)
                            ForEach(regions, id: \.self) { r in
                                Button { region = r } label: { Chip(title: r, selected: region == r) }.buttonStyle(.plain)
                            }
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                ForEach(groups) { g in
                    Button { onPick(.group(g.id)) } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(g.label.title).font(.body)
                                if let r = g.label.region { Text(r).font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            if model.user.lockedGroups.contains(g.id) { Image(systemName: "lock.fill").foregroundStyle(.secondary) }
                            Text("\(g.count)").foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    .tint(.primary)
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("Groups")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Search groups")
        }
    }
}

// MARK: - Schedule / catch-up / reminders

struct ScheduleView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let channel: Channel
    @State private var dayOffset = 0
    @State private var reminded: Set<String> = []

    private var calendar: Calendar { .current }

    private var dayStart: Date {
        calendar.date(byAdding: .day, value: dayOffset, to: calendar.startOfDay(for: Date())) ?? Date()
    }

    private var programmes: [Programme] {
        model.schedule(for: channel, from: dayStart, to: dayStart.addingTimeInterval(86_400))
    }

    private var minDay: Int { channel.hasCatchup ? -(channel.catchup?.days ?? 0) : 0 }

    var body: some View {
        NavigationStack {
            let now = Date()
            List {
                Picker("Day", selection: $dayOffset) {
                    ForEach(max(minDay, -3)...2, id: \.self) { d in
                        Text(dayLabel(d)).tag(d)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)

                if programmes.isEmpty {
                    ContentUnavailableView("No guide data", systemImage: "calendar.badge.exclamationmark",
                                           description: Text("This channel has no schedule for the selected day."))
                        .listRowBackground(Color.clear)
                }
                ForEach(programmes) { p in
                    let isNow = p.start <= now && p.stop > now
                    let isPast = p.stop <= now
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(Fmt.range(p)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            if isNow { LiveDot() }
                            Spacer()
                            action(for: p, isNow: isNow, isPast: isPast)
                        }
                        Text(p.title).font(.headline)
                        if let d = p.desc, !d.isEmpty { Text(d).font(.footnote).foregroundStyle(.secondary).lineLimit(3) }
                        if isNow { ProgressView(value: p.progress(at: now)).tint(Theme.accent) }
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(isNow ? Color.white.opacity(0.08) : Color.clear)
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle(channel.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .task { await model.ensureGuide(for: channel) }
            .onAppear { reminded = Set(model.user.reminders.map(\.id)) }
        }
        .presentationBackground(.ultraThinMaterial)
    }

    @ViewBuilder
    private func action(for p: Programme, isNow: Bool, isPast: Bool) -> some View {
        if isNow {
            Button("Watch") { dismiss(); UIState.shared.play(channel) }.glassButtonStyle(prominent: true).controlSize(.small)
        } else if isPast {
            if let url = CatchupBuilder.url(for: channel, programme: unshifted(p)) {
                Button { play(catchup: url, p) } label: { Label("Replay", systemImage: "gobackward") }
                    .glassButtonStyle().controlSize(.small)
            }
        } else {
            let r = Reminder(channelID: channel.id, channelName: channel.name, title: p.title, start: p.start)
            let on = reminded.contains(r.id)
            Button {
                if on {
                    ReminderCenter.cancel(r)
                    model.updateUser { $0.reminders.removeAll { $0.id == r.id } }
                    reminded.remove(r.id)
                } else {
                    Task {
                        if await ReminderCenter.schedule(r) {
                            model.updateUser { $0.reminders.append(r) }
                            reminded.insert(r.id)
                        }
                    }
                }
            } label: { Image(systemName: on ? "bell.fill" : "bell") }
            .glassButtonStyle().controlSize(.small)
        }
    }

    /// Catch-up URLs need the provider's clock, i.e. the programme time *before* our display offset.
    private func unshifted(_ p: Programme) -> Programme {
        let off = model.epgOffset(for: channel)
        var q = p
        q.start = p.start.addingTimeInterval(-off)
        q.stop = p.stop.addingTimeInterval(-off)
        return q
    }

    private func play(catchup url: URL, _ p: Programme) {
        guard var ep = channel.primary else { return }
        ep.url = url
        dismiss()
        UIState.shared.play(PlayableVOD(id: "cu:\(channel.id):\(Int(p.start.timeIntervalSince1970))", title: "\(channel.name) · \(p.title)", endpoint: ep, poster: channel.logo))
    }

    private func dayLabel(_ d: Int) -> String {
        switch d {
        case 0: "Today"
        case 1: "Tomorrow"
        case -1: "Yesterday"
        default:
            (calendar.date(byAdding: .day, value: d, to: Date()) ?? Date()).formatted(.dateTime.weekday(.abbreviated))
        }
    }
}
