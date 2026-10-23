import Foundation
import Testing
@testable import LuminaCore

#if os(macOS)
/// End-to-end over real HTTP: a throwaway local web server hands out a playlist and a gzipped XMLTV guide.
@Suite(.serialized) struct NetworkTests {
    final class Server {
        let process = Process()
        let dir: URL
        let port: Int

        init(files: [String: Data]) throws {
            dir = FileManager.default.temporaryDirectory.appendingPathComponent("lumina-http-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for (n, d) in files { try d.write(to: dir.appendingPathComponent(n)) }
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = ["-u", "-m", "http.server", "0", "--bind", "127.0.0.1", "--directory", dir.path]
            process.standardOutput = pipe
            process.standardError = Pipe()
            try process.run()
            // "Serving HTTP on 127.0.0.1 port 54321 ..."
            var buf = Data()
            var found: Int?
            let deadline = Date().addingTimeInterval(8)
            while found == nil, Date() < deadline {
                let chunk = pipe.fileHandleForReading.availableData
                if chunk.isEmpty { Thread.sleep(forTimeInterval: 0.05); continue }
                buf.append(chunk)
                let text = String(decoding: buf, as: UTF8.self)
                if let r = text.range(of: #"port (\d+)"#, options: .regularExpression) {
                    found = Int(text[r].dropFirst(5))
                }
            }
            guard let p = found else { process.terminate(); throw LuminaError.network("server did not start") }
            port = p
        }

        func url(_ name: String) -> URL { URL(string: "http://127.0.0.1:\(port)/\(name)")! }
        deinit { process.terminate(); try? FileManager.default.removeItem(at: dir) }
    }

    static func gzip(_ data: Data) throws -> Data {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("g-\(UUID().uuidString)")
        try data.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp); try? FileManager.default.removeItem(atPath: tmp.path + ".gz") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        p.arguments = ["-k", tmp.path]
        try p.run(); p.waitUntilExit()
        return try Data(contentsOf: URL(fileURLWithPath: tmp.path + ".gz"))
    }

    @Test func playlistAndGzippedGuideOverHTTP() async throws {
        // Reserve the port first so the playlist can point at its own guide.
        let probe = try Server(files: [:])
        let port = probe.port
        probe.process.terminate()

        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(secondsFromGMT: 0)
        fmt.dateFormat = "yyyyMMddHHmmss"
        let now = Date()
        func t(_ off: TimeInterval) -> String { fmt.string(from: now.addingTimeInterval(off)) + " +0000" }
        let xml = """
        <?xml version="1.0"?><tv>
        <channel id="one.tv"><display-name>One</display-name></channel>
        <programme start="\(t(-1800))" stop="\(t(1800))" channel="one.tv"><title>Right Now</title></programme>
        <programme start="\(t(1800))" stop="\(t(5400))" channel="one.tv"><title>Coming Up</title></programme>
        </tv>
        """
        let gz = try Self.gzip(Data(xml.utf8))

        let server = try Server(files: [
            "guide.xml.gz": gz,
            "list.m3u": Data("""
            #EXTM3U url-tvg="http://127.0.0.1:0/guide.xml.gz"
            #EXTINF:-1 tvg-id="one.tv" group-title="News",One HD
            http://127.0.0.1/one.m3u8
            """.utf8),
        ])
        _ = port

        let loader = PlaylistLoader()
        let id = UUID()
        let snap = try await loader.load(Source(id: id, name: "t", kind: .m3u(server.url("list.m3u"))))
        #expect(snap.channels.count == 1)
        #expect(snap.channels[0].epgID == "one.tv")

        let r = try await loader.loadGuide(
            server.url("guide.xml.gz"), wantedIDs: ["one.tv"], wantedNameKeys: [],
            window: now.addingTimeInterval(-86_400)...now.addingTimeInterval(86_400)
        )
        #expect(r.programmes.count == 2)
        let nn = r.index.nowNext(for: snap.channels[0], at: now)
        #expect(nn.now?.title == "Right Now")
        #expect(nn.next?.title == "Coming Up")

        // 404 gives a friendly, typed error.
        await #expect(throws: LuminaError.http(404)) {
            _ = try await loader.load(Source(name: "x", kind: .m3u(server.url("missing.m3u"))))
        }
    }

    @Test func healthProbeAndScan() async throws {
        let server = try Server(files: [
            "ok.m3u8": Data("#EXTM3U\n#EXT-X-VERSION:3\n".utf8),
            "bad.m3u8": Data("<html>nope</html>".utf8),
        ])
        func ch(_ id: String, _ file: String) -> Channel {
            Channel(id: id, sourceID: UUID(), name: id, group: "g", streams: [StreamEndpoint(url: server.url(file))])
        }
        let channels = [ch("ok", "ok.m3u8"), ch("bad", "bad.m3u8"), ch("missing", "nope.m3u8"),
                        Channel(id: "refused", sourceID: UUID(), name: "r", group: "g",
                                streams: [StreamEndpoint(url: URL(string: "http://127.0.0.1:1/x.m3u8")!)])]
        var alive: [String: Bool] = [:]
        for await r in StreamHealth.scan(channels, concurrency: 2) { alive[r.channelID] = r.alive }
        #expect(alive == ["ok": true, "bad": false, "missing": false, "refused": false])
    }
}
#endif
