import SwiftUI
import LuminaCore

enum Theme {
    static let accent = Color(red: 0.35, green: 0.80, blue: 1.00)
    static let accent2 = Color(red: 0.60, green: 0.45, blue: 1.00)
    static let live = Color(red: 1.00, green: 0.30, blue: 0.35)

    static let gradient = LinearGradient(colors: [accent, accent2], startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// Deep, quiet backdrop with two soft colour pools. Cheap: static gradients, no blur layers.
struct AppBackground: View {
    var body: some View {
        ZStack {
            Color(red: 0.03, green: 0.04, blue: 0.07)
            RadialGradient(colors: [Theme.accent.opacity(0.22), .clear], center: .topLeading, startRadius: 0, endRadius: 420)
            RadialGradient(colors: [Theme.accent2.opacity(0.20), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 480)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Liquid Glass with graceful fallback

extension View {
    /// Liquid Glass on iOS 26+, ultra-thin material before. Use for chrome (bars, chips, buttons, cards),
    /// not for every list row, so scrolling stays smooth.
    @ViewBuilder
    func glass(_ radius: CGFloat = 22, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            let g: Glass = {
                var g = Glass.regular
                if let tint { g = g.tint(tint) }
                if interactive { g = g.interactive() }
                return g
            }()
            self.glassEffect(g, in: .rect(cornerRadius: radius))
        } else {
            self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(.white.opacity(0.10)))
        }
    }

    @ViewBuilder
    func glassCapsule(tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            let g: Glass = {
                var g = Glass.regular
                if let tint { g = g.tint(tint) }
                if interactive { g = g.interactive() }
                return g
            }()
            self.glassEffect(g, in: .capsule)
        } else {
            self.background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.10)))
        }
    }

    @ViewBuilder
    func glassButtonStyle(prominent: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            if prominent { self.buttonStyle(.glassProminent) } else { self.buttonStyle(.glass) }
        } else {
            if prominent { self.buttonStyle(.borderedProminent) } else { self.buttonStyle(.bordered) }
        }
    }

    /// Flat translucent fill for list rows (cheap to render in long lists).
    func rowCard(_ radius: CGFloat = 16) -> some View {
        self.background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// Round glass icon button used on the player and in headers.
struct GlassIconButton: View {
    let systemName: String
    var size: CGFloat = 44
    var tint: Color? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.4, weight: .semibold))
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassCapsule(tint: tint, interactive: true)
        .accessibilityLabel(Text(systemName))
    }
}

struct Chip: View {
    let title: String
    var systemImage: String?
    var selected = false

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage { Image(systemName: systemImage).font(.footnote.weight(.semibold)) }
            Text(title).font(.subheadline.weight(.medium)).lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .foregroundStyle(selected ? Color.black : Color.primary)
        .background(selected ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Color.clear), in: Capsule())
        .glassCapsule(interactive: true)
    }
}

struct QualityBadge: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(.secondary)
    }
}

struct LiveDot: View {
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(Theme.live).frame(width: 6, height: 6)
            Text("LIVE").font(.system(size: 10, weight: .heavy, design: .rounded))
        }
        .foregroundStyle(Theme.live)
    }
}

// MARK: - Images

struct LogoView: View {
    let url: URL?
    var size: CGFloat = 54
    var corner: CGFloat = 12
    var symbol = "tv"
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: corner, style: .continuous).fill(.white.opacity(0.08))
            if let image {
                Image(uiImage: image).resizable().scaledToFit().padding(5)
            } else {
                Image(systemName: symbol).font(.system(size: size * 0.34)).foregroundStyle(.tertiary)
            }
        }
        .frame(width: size, height: size)
        .task(id: url) {
            guard let url else { image = nil; return }
            image = await ImageLoader.shared.image(url, maxPixel: size * 3)
        }
    }
}

struct PosterView: View {
    let url: URL?
    var corner: CGFloat = 14
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: corner, style: .continuous).fill(.white.opacity(0.07))
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "film").font(.title).foregroundStyle(.tertiary)
            }
        }
        .aspectRatio(2.0 / 3.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .task(id: url) {
            guard let url else { image = nil; return }
            image = await ImageLoader.shared.image(url, maxPixel: 420)
        }
    }
}

// MARK: - Formatting

enum Fmt {
    static let time: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    static func range(_ p: Programme) -> String { "\(time.string(from: p.start)) – \(time.string(from: p.stop))" }

    static func duration(_ s: TimeInterval) -> String {
        let t = Int(s)
        let h = t / 3600, m = (t % 3600) / 60, sec = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}
