import SwiftUI
import LuminaCore

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Bindable private var ui = UIState.shared

    var body: some View {
        ZStack {
            AppBackground()
            if model.booted && !model.hasSources {
                WelcomeView()
            } else {
                TabView(selection: $ui.tab) {
                    LiveView()
                        .tabItem { Label("Live", systemImage: "play.tv") }
                        .tag(AppTab.live)
                    LibraryView()
                        .tabItem { Label("Library", systemImage: "film.stack") }
                        .tag(AppTab.library)
                    SearchView()
                        .tabItem { Label("Search", systemImage: "magnifyingglass") }
                        .tag(AppTab.search)
                    SettingsView()
                        .tabItem { Label("Settings", systemImage: "slider.horizontal.3") }
                        .tag(AppTab.settings)
                }
            }
        }
        .overlay(alignment: .top) { StatusBanner() }
        .onOpenURL { url in Task { await model.handleOpen(url) } }
        .fullScreenCover(isPresented: $ui.showPlayer) { PlayerScreen() }
        .sheet(item: $ui.pinRequest) { PINPromptView(request: $0) }
    }
}

/// Slim progress / error line. Errors never block the UI; they sit on top and fade.
struct StatusBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 6) {
            if case .loading(let text) = model.loadState {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(text).font(.footnote.weight(.medium))
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .glassCapsule()
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            if let err = model.lastError {
                Text(err).font(.footnote).multilineTextAlignment(.leading)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .glass(16, tint: Theme.live.opacity(0.25))
                    .padding(.horizontal)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.top, 4)
        .animation(.smooth, value: model.loadState)
        .animation(.smooth, value: model.lastError)
        .allowsHitTesting(false)
    }
}

/// Floating "now playing" capsule above the tab bar.
struct MiniPlayer: ViewModifier {
    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 8) {
            MiniPlayerBar()
        }
    }
}

extension View {
    func miniPlayerInset() -> some View { modifier(MiniPlayer()) }
}

struct MiniPlayerBar: View {
    @Environment(AppModel.self) private var model
    private let player = PlayerController.shared

    var body: some View {
        if player.hasMedia {
            let nn = player.channel.map { model.nowNext($0) }
            HStack(spacing: 12) {
                LogoView(url: player.channel?.logo, size: 40, corner: 10, symbol: player.vod == nil ? "tv" : "film")
                VStack(alignment: .leading, spacing: 1) {
                    Text(player.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(subtitle(nn?.now)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if player.isLive {
                    Button { player.zap(-1) } label: { Image(systemName: "backward.fill") }
                        .buttonStyle(.plain)
                }
                Button { player.togglePlayPause() } label: {
                    Image(systemName: player.isPlaying || player.isBuffering ? "pause.fill" : "play.fill")
                        .font(.title3).frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                if player.isLive {
                    Button { player.zap(1) } label: { Image(systemName: "forward.fill") }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .glass(26, interactive: true)
            .padding(.horizontal, 12)
            .contentShape(Rectangle())
            .onTapGesture { UIState.shared.showPlayer = true }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func subtitle(_ p: Programme?) -> String {
        switch player.status {
        case .loading: "Connecting…"
        case .failed: "Can't play this channel"
        default: p?.title ?? (player.isLive ? "Live" : "")
        }
    }
}

// MARK: - First run

struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @State private var add: AddSourceView.Mode?

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            ZStack {
                Circle().fill(Theme.gradient).frame(width: 96, height: 96).blur(radius: 24).opacity(0.6)
                Image(systemName: "play.tv.fill")
                    .font(.system(size: 52, weight: .semibold))
                    .foregroundStyle(Theme.gradient)
            }
            VStack(spacing: 8) {
                Text("Lumina").font(.system(size: 40, weight: .bold, design: .rounded))
                Text("Your live TV, movies and series.\nOne calm place, on your phone and in your car.")
                    .font(.body).multilineTextAlignment(.center).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(spacing: 12) {
                Button { add = .xtream } label: { label("Sign in with Xtream login", "person.badge.key") }
                    .glassButtonStyle(prominent: true)
                Button { add = .m3u } label: { label("Add an M3U link", "link") }
                    .glassButtonStyle()
                Button { add = .file } label: { label("Import a playlist file", "doc") }
                    .glassButtonStyle()
                Button("Try the demo first") { Task { await model.addDemo() } }
                    .font(.subheadline).padding(.top, 4)
            }
            .controlSize(.large)
            .padding(.horizontal, 28)
            Text("Lumina doesn't include any channels. Add playlists from a provider you have the right to use.")
                .font(.caption2).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                .padding(.horizontal, 36).padding(.bottom, 12)
        }
        .sheet(item: $add) { AddSourceView(mode: $0) }
    }

    private func label(_ t: String, _ icon: String) -> some View {
        Label(t, systemImage: icon).frame(maxWidth: .infinity)
    }
}
