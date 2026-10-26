import Foundation

/// A GitHub release of Cartridge.
public struct Release: Decodable, Hashable, Sendable, Identifiable {
    public struct Asset: Decodable, Hashable, Sendable {
        public var name: String
        public var browserDownloadURL: URL
        public var size: Int

        enum CodingKeys: String, CodingKey {
            case name, size
            case browserDownloadURL = "browser_download_url"
        }
    }

    public var tagName: String
    public var name: String?
    public var body: String?
    public var htmlURL: URL
    public var publishedAt: Date?
    public var draft: Bool
    public var prerelease: Bool
    public var assets: [Asset]

    public var id: String { tagName }
    public var version: String { Version.normalize(tagName) }
    public var title: String { (name?.isEmpty == false ? name! : "Cartridge \(version)") }
    public func asset(named name: String) -> Asset? { assets.first { $0.name == name } }

    enum CodingKeys: String, CodingKey {
        case name, body, draft, prerelease, assets
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case publishedAt = "published_at"
    }

    public static func decodeList(_ data: Data) throws -> [Release] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([Release].self, from: data)
    }
}

public enum Version {
    /// "v1.2.0" → "1.2.0"
    public static func normalize(_ s: String) -> String {
        var v = s.trimmingCharacters(in: .whitespaces)
        if v.lowercased().hasPrefix("v") { v.removeFirst() }
        return v
    }

    /// Numeric comparison of dotted versions: 1.10.0 > 1.9.3, 1.0 == 1.0.0.
    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let pa = normalize(a).split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        let pb = normalize(b).split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        compare(candidate, current) == .orderedDescending
    }

    /// Published, non-prerelease releases newer than `current`, newest first.
    public static func updates(from releases: [Release], current: String) -> [Release] {
        releases.filter { !$0.draft && !$0.prerelease && isNewer($0.version, than: current) }
            .sorted { isNewer($0.version, than: $1.version) }
    }
}

/// Splits release-note Markdown into blocks the app can render natively.
public enum ReleaseNotes {
    public enum Block: Hashable, Sendable {
        case heading(String)
        case bullet(String)
        case paragraph(String)
    }

    public static func parse(_ markdown: String) -> [Block] {
        var blocks = [Block]()
        var paragraph = [String]()
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))); paragraph = [] }
        }
        for raw in markdown.replacingOccurrences(of: "\r", with: "").split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            if line.hasPrefix("#") {
                flush()
                blocks.append(.heading(line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flush()
                blocks.append(.bullet(String(line.dropFirst(2))))
            } else if raw.hasPrefix("  "), case .bullet(let text)? = blocks.last {
                blocks[blocks.count - 1] = .bullet(text + " " + line) // wrapped bullet
            } else {
                paragraph.append(line)
            }
        }
        flush()
        return blocks
    }
}
