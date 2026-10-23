import SwiftUI
import LuminaCore

struct LibraryView: View {
    enum Kind: String, CaseIterable, Identifiable {
        case movies = "Movies", series = "Series"
        var id: String { rawValue }
    }

    @Environment(AppModel.self) private var model
    @State private var kind: Kind = .movies
    @State private var category: String?
    @State private var query = ""
    @State private var shownMovies: [VODItem] = []
    @State private var shownSeries: [Series] = []

    private var categories: [String] {
        let names = kind == .movies ? model.movies.map(\.category) : model.series.map(\.category)
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    Picker("Kind", selection: $kind) {
                        ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)

                    if query.isEmpty && category == nil && !model.continueWatching.isEmpty {
                        continueRow
                    }
                    if !categories.isEmpty { categoryChips }

                    if (kind == .movies ? model.movies.isEmpty : model.series.isEmpty) {
                        ContentUnavailableView(
                            "No \(kind.rawValue.lowercased()) yet", systemImage: "film",
                            description: Text("Movies and series appear here when your provider includes them (Xtream logins do).")
                        ).padding(.top, 40)
                    } else {
                        grid
                    }
                }
                .padding(.bottom, 24)
            }
            .background(AppBackground())
            .navigationTitle("Library")
            .searchable(text: $query, prompt: "Search \(kind.rawValue.lowercased())")
            .task(id: "\(kind.rawValue)|\(category ?? "")|\(query)|\(model.libraryVersion)") { await refilter() }
            .onChange(of: kind) { category = nil }
            .miniPlayerInset()
        }
    }

    private var continueRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Continue watching").font(.title3.weight(.semibold)).padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(model.continueWatching) { entry in
                        Button { resume(entry.id, entry.progress) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                PosterView(url: entry.progress.poster).frame(width: 110)
                                ProgressView(value: entry.progress.fraction).tint(Theme.accent).frame(width: 110)
                                Text(entry.progress.title).font(.caption).lineLimit(1).frame(width: 110, alignment: .leading)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button { category = nil } label: { Chip(title: "All", selected: category == nil) }.buttonStyle(.plain)
                ForEach(categories, id: \.self) { c in
                    Button { category = c } label: { Chip(title: GroupLabel.parse(c).title, selected: category == c) }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private var grid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 12)], spacing: 16) {
            if kind == .movies {
                ForEach(shownMovies) { m in
                    NavigationLink { MovieDetailView(movie: m) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            PosterView(url: m.poster)
                            Text(m.title).font(.caption.weight(.medium)).lineLimit(2).multilineTextAlignment(.leading)
                        }
                    }
                    .buttonStyle(.plain)
                }
            } else {
                ForEach(shownSeries) { s in
                    NavigationLink { SeriesDetailView(series: s) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            PosterView(url: s.poster)
                            Text(s.title).font(.caption.weight(.medium)).lineLimit(2).multilineTextAlignment(.leading)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 16)
    }

    /// Filtering tens of thousands of titles on every keystroke would stutter, so do it off the render path.
    private func refilter() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        let cat = category
        let movies = model.movies, series = model.series
        let isMovies = kind == .movies
        if q.isEmpty == false { try? await Task.sleep(for: .milliseconds(180)) }
        if Task.isCancelled { return }
        if isMovies {
            let r = await Task.detached(priority: .userInitiated) {
                movies.filter { (cat == nil || $0.category == cat) && (q.isEmpty || $0.title.localizedCaseInsensitiveContains(q)) }.prefix(600).map { $0 }
            }.value
            shownMovies = r
        } else {
            let r = await Task.detached(priority: .userInitiated) {
                series.filter { (cat == nil || $0.category == cat) && (q.isEmpty || $0.title.localizedCaseInsensitiveContains(q)) }.prefix(600).map { $0 }
            }.value
            shownSeries = r
        }
    }

    private func resume(_ id: String, _ p: WatchProgress) {
        guard let url = p.streamURL else { return }
        UIState.shared.play(
            PlayableVOD(id: id, title: p.title, endpoint: StreamEndpoint(url: url), poster: p.poster),
            resumeAt: max(0, p.position - 3)
        )
    }
}

// MARK: - Movie

struct MovieDetailView: View {
    @Environment(AppModel.self) private var model
    let movie: VODItem
    @State private var detail: VODDetail?

    private var progress: WatchProgress? { model.user.progress[movie.id] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .bottom, spacing: 16) {
                    PosterView(url: detail?.poster ?? movie.poster).frame(width: 130)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(movie.title).font(.title2.weight(.bold))
                        HStack(spacing: 8) {
                            if let y = detail?.year ?? movie.year { QualityBadge(text: y) }
                            if let r = detail?.rating ?? movie.rating, r > 0 { QualityBadge(text: String(format: "★ %.1f", r)) }
                            if let d = detail?.duration { QualityBadge(text: d) }
                        }
                    }
                }
                HStack {
                    Button { play(resume: false) } label: { Label(resumeLabel, systemImage: "play.fill").frame(maxWidth: .infinity) }
                        .glassButtonStyle(prominent: true)
                    if let p = progress, !p.isFinished, p.position > 20 {
                        Button { play(resume: false, fromStart: true) } label: { Label("Start over", systemImage: "arrow.counterclockwise") }
                            .glassButtonStyle()
                    }
                }
                .controlSize(.large)
                if let plot = detail?.plot ?? movie.plot { Text(plot).font(.body).foregroundStyle(.secondary) }
                if let g = detail?.genre { info("Genre", g) }
                if let c = detail?.cast { info("Cast", c) }
                if let d = detail?.director { info("Director", d) }
            }
            .padding(16)
        }
        .navigationBarTitleDisplayMode(.inline)
        .task { detail = await model.detail(for: movie) }
        .miniPlayerInset()
    }

    private var resumeLabel: String {
        if let p = progress, !p.isFinished, p.position > 20 { return "Resume \(Fmt.duration(p.position))" }
        return "Play"
    }

    private func info(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(k).font(.caption).foregroundStyle(.tertiary)
            Text(v).font(.subheadline)
        }
    }

    private func play(resume: Bool, fromStart: Bool = false) {
        var ep = movie.stream
        if let ext = detail?.containerExtension, ext != ep.url.pathExtension {
            ep.url = ep.url.deletingPathExtension().appendingPathExtension(ext)
        }
        let at = (progress.map { $0.isFinished ? 0 : max(0, $0.position - 3) } ?? 0)
        UIState.shared.play(
            PlayableVOD(id: movie.id, title: movie.title, endpoint: ep, poster: movie.poster),
            resumeAt: fromStart ? 0 : at
        )
    }
}

// MARK: - Series

struct SeriesDetailView: View {
    @Environment(AppModel.self) private var model
    let series: Series
    @State private var episodes: [Episode] = []
    @State private var season = 1
    @State private var loading = true

    private var seasons: [Int] { Array(Set(episodes.map(\.season))).sorted() }
    private var current: [Episode] { episodes.filter { $0.season == season }.sorted { $0.number < $1.number } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .bottom, spacing: 16) {
                    PosterView(url: series.poster).frame(width: 120)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(series.title).font(.title2.weight(.bold))
                        HStack(spacing: 8) {
                            if let y = series.year { QualityBadge(text: y) }
                            if let r = series.rating, r > 0 { QualityBadge(text: String(format: "★ %.1f", r)) }
                        }
                    }
                }
                if let plot = series.plot { Text(plot).font(.subheadline).foregroundStyle(.secondary) }

                if loading {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 20)
                } else if episodes.isEmpty {
                    ContentUnavailableView("No episodes", systemImage: "tv.slash")
                } else {
                    if seasons.count > 1 {
                        Menu {
                            ForEach(seasons, id: \.self) { s in Button("Season \(s)") { season = s } }
                        } label: {
                            Label("Season \(season)", systemImage: "chevron.up.chevron.down").padding(.horizontal, 6)
                        }
                        .glassButtonStyle()
                    }
                    ForEach(current) { ep in
                        let p = model.user.progress[ep.id]
                        Button { play(ep, resume: p) } label: {
                            HStack(spacing: 12) {
                                Text("\(ep.number)").font(.title3.monospacedDigit().weight(.semibold)).frame(width: 34).foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(ep.title).font(.subheadline.weight(.semibold)).lineLimit(2).multilineTextAlignment(.leading)
                                    if let plot = ep.plot { Text(plot).font(.caption).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading) }
                                    if let p, !p.isFinished { ProgressView(value: p.fraction).tint(Theme.accent) }
                                }
                                Spacer(minLength: 0)
                                Image(systemName: p?.isFinished == true ? "checkmark.circle.fill" : "play.circle")
                                    .foregroundStyle(p?.isFinished == true ? Theme.accent : .secondary)
                            }
                            .padding(12).rowCard()
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(16)
        }
        .navigationBarTitleDisplayMode(.inline)
        .task {
            episodes = await model.episodes(for: series)
            season = seasons.first ?? 1
            loading = false
        }
        .miniPlayerInset()
    }

    private func play(_ ep: Episode, resume: WatchProgress?) {
        // Auto-play continues through the rest of the season, then following seasons.
        let all = episodes.sorted { ($0.season, $0.number) < ($1.season, $1.number) }
        let idx = all.firstIndex(of: ep) ?? 0
        let queue = all.suffix(from: min(idx + 1, all.count)).map {
            PlayableVOD(id: $0.id, title: "\(series.title) · \($0.title)", endpoint: $0.stream, poster: series.poster)
        }
        let at = resume.map { $0.isFinished ? 0 : max(0, $0.position - 3) } ?? 0
        UIState.shared.play(
            PlayableVOD(id: ep.id, title: "\(series.title) · \(ep.title)", endpoint: ep.stream, poster: series.poster),
            queue: Array(queue), resumeAt: at
        )
    }
}

// MARK: - Search

struct SearchView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var results = SearchResults()
    @State private var programmes: [(Programme, Channel)] = []

    var body: some View {
        NavigationStack {
            List {
                if query.isEmpty {
                    ContentUnavailableView("Search everything", systemImage: "magnifyingglass",
                                           description: Text("Channels, what's on now and next, movies and series — in one box."))
                        .listRowBackground(Color.clear)
                } else if results.isEmpty && programmes.isEmpty {
                    ContentUnavailableView.search(text: query).listRowBackground(Color.clear)
                }
                if !results.channels.isEmpty {
                    Section("Channels") {
                        ForEach(results.channels) { ch in
                            Button { UIState.shared.play(ch, in: results.channels) } label: {
                                HStack(spacing: 12) {
                                    LogoView(url: ch.logo, size: 40, corner: 10)
                                    VStack(alignment: .leading) {
                                        Text(ch.name).font(.body)
                                        if let p = model.nowNext(ch).now { Text(p.title).font(.caption).foregroundStyle(.secondary) }
                                    }
                                }
                            }
                            .tint(.primary)
                        }
                    }
                }
                if !programmes.isEmpty {
                    Section("On TV soon") {
                        ForEach(programmes, id: \.0.id) { p, ch in
                            Button { UIState.shared.play(ch) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(p.title).font(.body)
                                    Text("\(ch.name) · \(Fmt.time.string(from: p.start))").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .tint(.primary)
                        }
                    }
                }
                if !results.movies.isEmpty {
                    Section("Movies") {
                        ForEach(results.movies) { m in
                            NavigationLink { MovieDetailView(movie: m) } label: {
                                HStack(spacing: 12) {
                                    PosterView(url: m.poster, corner: 6).frame(width: 34)
                                    Text(m.title)
                                }
                            }
                        }
                    }
                }
                if !results.series.isEmpty {
                    Section("Series") {
                        ForEach(results.series) { s in
                            NavigationLink { SeriesDetailView(series: s) } label: {
                                HStack(spacing: 12) {
                                    PosterView(url: s.poster, corner: 6).frame(width: 34)
                                    Text(s.title)
                                }
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .listStyle(.insetGrouped)
            .background(AppBackground())
            .navigationTitle("Search")
            .searchable(text: $query, prompt: "Channels, shows, movies")
            .task(id: query) {
                try? await Task.sleep(for: .milliseconds(160))
                guard !Task.isCancelled else { return }
                results = model.search(query)
                programmes = model.programmeSearch(query)
            }
            .miniPlayerInset()
        }
    }
}
