import Foundation

public enum NameNormalizer {
    /// Tags providers glue onto channel names that say nothing about *which* channel it is.
    public static let noise: Set<String> = [
        "hd", "fhd", "uhd", "4k", "sd", "hevc", "h265", "h264", "raw", "hq", "lq", "fullhd",
        "1080p", "1080i", "720p", "576p", "480p", "2160p", "50fps", "60fps", "backup", "vip",
    ]

    /// Lower-cased, diacritic-folded alphanumeric tokens.
    public static func tokens(_ s: String) -> [String] {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    /// Key used for search and for merging duplicate channels (quality tags removed).
    public static func key(_ name: String) -> String {
        tokens(name).filter { !noise.contains($0) }.joined(separator: " ")
    }
}
