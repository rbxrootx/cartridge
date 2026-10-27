import Foundation

/// One file of a game folder, parsed from the usual "Name [TitleID][vVersion].nsp" naming.
public struct GameFile: Hashable, Sendable {
    public enum Kind: String, Sendable { case base, update, dlc, unknown }

    public var url: URL
    public var titleID: String?
    public var version: Int?
    public var size: Int64

    public var kind: Kind {
        guard let id = titleID, let value = UInt64(id, radix: 16) else { return .unknown }
        switch value & 0xFFF {
        case 0: return .base
        case 0x800: return .update
        default: return .dlc
        }
    }

    /// The base game's title ID this file belongs to.
    public var baseTitleID: String? {
        guard let id = titleID, let value = UInt64(id, radix: 16) else { return nil }
        let base: UInt64 = switch kind {
        case .base: value
        case .update: value - 0x800
        case .dlc: (value - 0x1000) & ~0xFFF
        case .unknown: value
        }
        return String(format: "%016llX", base)
    }

    public static let extensions: Set<String> = ["nsp", "xci", "nsz", "xcz"]

    public static func parse(_ url: URL, size: Int64 = 0) -> GameFile {
        let name = url.lastPathComponent
        let id = name.firstMatch(of: /\[([0-9A-Fa-f]{16})\]/).map { String($0.1).uppercased() }
        let version = name.firstMatch(of: /\[v(\d+)\]/).flatMap { Int($0.1) }
        return GameFile(url: url, titleID: id, version: version, size: size)
    }

    /// Display name: the file name before the first "[".
    public var displayName: String {
        let stem = url.deletingPathExtension().lastPathComponent
        let name = stem.split(separator: "[", maxSplits: 1).first.map(String.init) ?? stem
        return name.trimmingCharacters(in: .whitespaces)
    }
}

/// A folder holding one game's files, as nxnative expects.
public struct GameFolder: Hashable, Sendable {
    public var url: URL
    public var files: [GameFile]
    /// Built apps and IPAs found in the folder, newest first.
    public var outputs: [Output]

    public struct Output: Hashable, Sendable {
        public var url: URL
        public var date: Date
        public var isMacApp: Bool { url.pathExtension == "app" }
    }

    public var base: GameFile? { files.first { $0.kind == .base } }
    public var updates: [GameFile] { files.filter { $0.kind == .update }.sorted { ($0.version ?? 0) < ($1.version ?? 0) } }
    public var dlc: [GameFile] { files.filter { $0.kind == .dlc } }
    public var totalSize: Int64 { files.reduce(0) { $0 + $1.size } }

    public var titleID: String? { base?.titleID ?? files.compactMap(\.baseTitleID).first }
    public var name: String {
        let n = base?.displayName ?? files.first?.displayName ?? ""
        return n.isEmpty ? url.lastPathComponent : n
    }

    /// Versions that can be packed (base v0 plus each update), newest last.
    public var versions: [Int] { Array(Set(files.filter { $0.kind != .dlc }.compactMap(\.version))).sorted() }

    /// nxnative needs about twice the game's size plus 10 GB free.
    public var requiredSpace: Int64 { totalSize * 2 + 10_000_000_000 }

    public var latestMacApp: Output? { outputs.first { $0.isMacApp } }
    public var latestIPA: Output? { outputs.first { !$0.isMacApp } }

    public static func scan(_ url: URL) -> GameFolder {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                                                 options: [.skipsHiddenFiles])) ?? []
        var files = [GameFile](), outputs = [Output]()
        for item in items {
            let ext = item.pathExtension.lowercased()
            let values = try? item.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            if GameFile.extensions.contains(ext) {
                files.append(.parse(item, size: Int64(values?.fileSize ?? 0)))
            } else if ext == "app" || ext == "ipa" {
                outputs.append(Output(url: item, date: values?.contentModificationDate ?? .distantPast))
            }
        }
        return GameFolder(url: url, files: files.sorted { $0.url.lastPathComponent < $1.url.lastPathComponent },
                          outputs: outputs.sorted { $0.date > $1.date })
    }

    /// Compares the folder's versions with the ones nxnative tested.
    public enum VersionCheck: Equatable, Sendable {
        case tested(Int)                    // a tested version is in the folder
        case untested(have: [Int], tested: [Catalog.TestedVersion])
        case unknown                        // no tested versions on record
    }

    public func versionCheck(_ entry: Catalog.Entry?) -> VersionCheck {
        guard let tested = entry?.testedVersions, !tested.isEmpty else { return .unknown }
        if let match = versions.reversed().first(where: { v in tested.contains { $0.code == v } }) { return .tested(match) }
        return .untested(have: versions, tested: tested)
    }

    /// Whether building `version` (nil = the newest in the folder) gives a version nxnative supports.
    /// nil when nxnative has no tested versions on record for the game.
    public func isCompatible(version: Int?, _ entry: Catalog.Entry?) -> Bool? {
        guard let tested = entry?.testedVersions, !tested.isEmpty, let v = version ?? versions.last else { return nil }
        return tested.contains { $0.code == v }
    }

    public static func versionLabel(_ v: Int) -> String {
        v == 0 ? "Base game (v0)" : "Update \(v >> 16) (v\(v))"
    }
}

/// Games nxnative has been tested with, read from the local checkout's docs.
public struct Catalog: Sendable {
    public struct Entry: Hashable, Sendable {
        public var titleID: String
        public var name: String
        public var notes: URL?
        public var artwork: URL?
        /// Versions nxnative registered for this game (`build` rows in its game.tsv), e.g. v1114112 = "1.9.0".
        public var testedVersions: [TestedVersion] = []
    }

    public struct TestedVersion: Hashable, Sendable {
        public var code: Int        // v-number, as in file names
        public var display: String  // "1.9.0"
    }

    /// `build<TAB>v1114112<TAB>1.9.0<TAB>…` rows.
    static func testedVersions(gameTSV: String) -> [TestedVersion] {
        gameTSV.split(separator: "\n").compactMap { line in
            let cols = line.split(separator: "\t")
            guard cols.count >= 3, cols[0] == "build", cols[1].hasPrefix("v"), let code = Int(cols[1].dropFirst()) else { return nil }
            return TestedVersion(code: code, display: String(cols[2]))
        }
    }

    public var entries: [String: Entry] = [:]

    public init() {}

    public init(repo: URL) {
        let gamesIndex = (try? String(contentsOf: repo.appendingPathComponent("dm/games/README.md"), encoding: .utf8)) ?? ""
        let readme = (try? String(contentsOf: repo.appendingPathComponent("README.md"), encoding: .utf8)) ?? ""
        entries = Self.parse(gamesIndex: gamesIndex, readme: readme, repo: repo)
    }

    public subscript(titleID: String?) -> Entry? { titleID.flatMap { entries[$0.uppercased()] } }

    static func normalize(_ s: String) -> String {
        s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }

    static func parse(gamesIndex: String, readme: String, repo: URL) -> [String: Entry] {
        // Artwork: <img src="docs/images/x.jpg" ... alt="Name">
        var art = [String: URL]()
        for m in readme.matches(of: /<img src="(docs\/images\/[^"]+)"[^>]*alt="([^"]+)"/) {
            art[normalize(String(m.2))] = repo.appendingPathComponent(String(m.1))
        }
        var result = [String: Entry]()
        // | [Name](ID/README.md) | `ID` | …
        for m in gamesIndex.matches(of: /^\| \[([^\]]+)\]\(([0-9A-Fa-f]{16})\/README\.md\) \| `([0-9A-Fa-f]{16})`/.anchorsMatchLineEndings()) {
            let name = String(m.1).replacingOccurrences(of: "&amp;", with: "&")
            let id = String(m.3).uppercased()
            let key = normalize(name)
            let artwork = art[key] ?? art.first { key.hasPrefix($0.key) || $0.key.hasPrefix(key) }?.value
            let tsv = (try? String(contentsOf: repo.appendingPathComponent("dm/games/\(m.2)/game.tsv"), encoding: .utf8)) ?? ""
            result[id] = Entry(titleID: id, name: name,
                               notes: repo.appendingPathComponent("dm/games/\(m.2)/README.md"), artwork: artwork,
                               testedVersions: testedVersions(gameTSV: tsv))
        }
        return result
    }
}

/// Events from `build_ipa_from_nsp.py --progress json`, one JSON object per line.
public enum BuildEvent: Sendable, Equatable {
    case stage(k: Int, n: Int, name: String, step: String)
    case step(k: Int, name: String, step: String)
    case progress(k: Int, name: String, step: String, fraction: Double?, eta: Double?, note: String?)
    case stageEnd(k: Int, name: String, ok: Bool, summary: String?, elapsed: Double)
    case message(String, Severity)
    case unparsed(String)

    public enum Severity: Sendable { case info, warning, error, success }

    public static func parse(_ line: String) -> BuildEvent {
        guard line.hasPrefix("{"), let data = line.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let ev = obj["ev"] as? String else {
            return .unparsed(line)
        }
        func int(_ k: String) -> Int { (obj[k] as? NSNumber)?.intValue ?? 0 }
        func str(_ k: String) -> String { obj[k] as? String ?? "" }
        func dbl(_ k: String) -> Double? { (obj[k] as? NSNumber)?.doubleValue }
        switch ev {
        case "stage": return .stage(k: int("k"), n: int("n"), name: str("name"), step: str("step"))
        case "step": return .step(k: int("k"), name: str("name"), step: str("step"))
        case "progress":
            return .progress(k: int("k"), name: str("name"), step: str("step"), fraction: dbl("frac"), eta: dbl("eta"),
                             note: obj["note"] as? String)
        case "stage_end":
            return .stageEnd(k: int("k"), name: str("name"), ok: (obj["ok"] as? Bool) ?? false,
                             summary: obj["summary"] as? String, elapsed: dbl("elapsed") ?? 0)
        case "say":
            return message(str("msg"))
        default:
            return .unparsed(line)
        }
    }

    /// Messages carry colour tags like "[RED] …"; turn them into a severity and strip them.
    static func message(_ raw: String) -> BuildEvent {
        var msg = raw, severity = Severity.info
        let tags: [(String, Severity)] = [("[RED]", .error), ("[YELLOW]", .warning), ("[GREEN]", .success)]
        for (tag, s) in tags where msg.contains(tag) {
            severity = s
            msg = msg.replacingOccurrences(of: tag, with: "")
        }
        msg = msg.replacing(/\[[A-Z]+\]/, with: "")
        msg = msg.replacing(/^\s*\[\d{1,2}:\d{2}:\d{2}\]\s*/, with: "") // leading timestamp
        return .message(msg.trimmingCharacters(in: .whitespaces), severity)
    }
}
