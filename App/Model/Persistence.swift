import Foundation
import LuminaCore

enum AppPaths {
    static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Lumina", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static var sources: URL { root.appendingPathComponent("sources.json") }
    static var user: URL { root.appendingPathComponent("user.json") }
    static var guide: URL { root.appendingPathComponent("guide-cache.json") }
    static var snapshots: URL {
        let d = root.appendingPathComponent("snapshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    static var imports: URL {
        let d = root.appendingPathComponent("imports", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func snapshot(_ id: UUID) -> URL { snapshots.appendingPathComponent("\(id.uuidString).json") }

    /// Imported playlist files live in our container; the absolute path changes across reinstalls/updates,
    /// so re-resolve by file name.
    static func resolveImport(_ url: URL) -> URL {
        guard url.isFileURL else { return url }
        return imports.appendingPathComponent(url.lastPathComponent)
    }
}

struct GuideCache: Codable {
    var programmes: [Programme]
    var channelNames: [String: [String]]
    var channelIcons: [String: String]
    var fetchedAt: Date

    init(from result: XMLTVResult, fetchedAt: Date = Date()) {
        programmes = result.programmes.map {
            var p = $0
            if let d = p.desc, d.count > 300 { p.desc = String(d.prefix(300)) }
            return p
        }
        channelNames = result.channelNames
        channelIcons = result.channelIcons.mapValues(\.absoluteString)
        self.fetchedAt = fetchedAt
    }

    var index: EPGIndex {
        EPGIndex(
            programmes: programmes, channelNames: channelNames,
            channelIcons: channelIcons.compactMapValues(URL.init(string:))
        )
    }
}
