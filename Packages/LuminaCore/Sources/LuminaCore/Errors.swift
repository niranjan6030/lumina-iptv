import Foundation

/// Every error carries wording a human can act on, never a raw status code dump.
public enum LuminaError: Error, LocalizedError, Equatable {
    case invalidURL
    case http(Int)
    case authFailed
    case accountInactive(String)
    case notAPlaylist
    case notAGuide
    case corruptArchive
    case emptyPlaylist
    case network(String)
    case decoding

    public var errorDescription: String? {
        switch self {
        case .invalidURL: "That address doesn't look right. Check it starts with http:// or https://."
        case .http(let c) where c == 401 || c == 403: "The server refused access (\(c)). Check your username, password or subscription."
        case .http(let c) where c == 404: "The server couldn't find that playlist (404). The link may have expired."
        case .http(let c): "The server answered with an error (\(c))."
        case .authFailed: "Login failed. Check the server address, username and password."
        case .accountInactive(let s): "This account is not active (\(s)). Contact your provider."
        case .notAPlaylist: "That link didn't return a playlist. It must be an M3U/M3U8 file."
        case .notAGuide: "The TV guide file couldn't be read."
        case .corruptArchive: "The compressed file is damaged."
        case .emptyPlaylist: "The playlist loaded but contains no channels."
        case .network(let m): "Network problem: \(m)"
        case .decoding: "The server replied in a format we couldn't understand."
        }
    }
}
