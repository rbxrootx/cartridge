import AppKit
import CartridgeCore
import Observation
import UserNotifications

struct LibraryGame: Codable, Identifiable, Hashable {
    var id = UUID()
    var folder: URL
    var added = Date()
    var lastBuild: BuildRecord?
}

struct BuildRecord: Codable, Hashable {
    var date: Date
    var platform: BuildOptions.Platform
    var ok: Bool
    var output: URL?
    var message: String?
}

struct BuildOptions: Codable, Hashable {
    enum Platform: String, Codable, CaseIterable, Identifiable {
        case macApp = "mac-app", ios
        var id: String { rawValue }
        var label: String { self == .macApp ? "Mac App" : "iPhone & iPad" }
    }
    var platform: Platform = .macApp
    var version: Int?           // nil = newest in the folder
    var language = ""           // "" = English (nxnative's default)
    var appName = ""
    var showFPS = false
    var keepExtracted = true
    var allowDamaged = false

    static let languages: [(String, String)] = [
        ("", "English"), ("en-GB", "English (UK)"), ("ja", "Japanese"), ("fr", "French"), ("fr-CA", "French (Canada)"),
        ("de", "German"), ("es", "Spanish"), ("es-419", "Spanish (Latin America)"), ("it", "Italian"), ("nl", "Dutch"),
        ("pt", "Portuguese"), ("pt-BR", "Portuguese (Brazil)"), ("ru", "Russian"), ("ko", "Korean"),
        ("zh-Hans", "Chinese (Simplified)"), ("zh-Hant", "Chinese (Traditional)"),
    ]
}

enum Sheet: Identifiable, Hashable {
    case game(UUID), setup, help
    var id: String {
        switch self {
        case .game(let id): "game-\(id)"
        case .setup: "setup"
        case .help: "help"
        }
    }
}

@MainActor
@Observable
final class Store {
    static let shared = Store()

    // Library
    private(set) var games: [LibraryGame] = []
    private(set) var folders: [UUID: GameFolder] = [:]
    var selection = 0          // index into games; games.count = the "Add Game" tile
    var focusRow = 0           // 0 = game tiles, 1 = the round buttons
    var buttonSelection = 0
    var sheet: Sheet?

    // Setup
    private(set) var requirements: [Requirement] = []
    private(set) var isChecking = false
    private(set) var fixing: Requirement.ID?
    private(set) var fixLog: [String] = []
    private(set) var catalog = Catalog()
    private(set) var repoStatus = ""
    private(set) var isUpdatingRepo = false

    // Building
    private(set) var build: BuildSession?

    // Settings
    var customRepoPath: String? { didSet { defaults.set(customRepoPath, forKey: "customRepoPath"); refresh() } }
    var keysPath: String? { didSet { defaults.set(keysPath, forKey: "keysPath"); Task { await check() } } }
    var defaultOptions: BuildOptions { didSet { defaults.set(try? JSONEncoder().encode(defaultOptions), forKey: "defaultOptions") } }
    var soundsEnabled: Bool { didSet { defaults.set(soundsEnabled, forKey: "sounds") } }

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var libraryURL: URL { Paths.support.appendingPathComponent("library.json") }

    var repo: URL { customRepoPath.map { URL(fileURLWithPath: $0) } ?? Paths.managedRepo }
    var keys: URL? { keysPath.map { URL(fileURLWithPath: $0) } }
    var isReady: Bool { !requirements.isEmpty && requirements.allSatisfy { $0.status == .ok || $0.id == .appleSilicon } }
    var missingCount: Int { requirements.filter { $0.status == .missing }.count }

    init() {
        customRepoPath = defaults.string(forKey: "customRepoPath")
        keysPath = defaults.string(forKey: "keysPath")
        defaultOptions = defaults.data(forKey: "defaultOptions").flatMap { try? JSONDecoder().decode(BuildOptions.self, from: $0) } ?? BuildOptions()
        soundsEnabled = defaults.object(forKey: "sounds") as? Bool ?? true
        if let data = try? Data(contentsOf: libraryURL), let saved = try? JSONDecoder().decode([LibraryGame].self, from: data) {
            games = saved
        }
        refresh()
        Task { await check() }
    }

    // MARK: Library

    func refresh() {
        for game in games { folders[game.id] = GameFolder.scan(game.folder) }
        catalog = Catalog(repo: repo)
        Task { repoStatus = await repoDescription() }
    }

    func add(folders urls: [URL]) {
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            // A dropped NSP means its folder.
            let folder = isDir.boolValue ? url : url.deletingLastPathComponent()
            guard !games.contains(where: { $0.folder.standardizedFileURL == folder.standardizedFileURL }) else { continue }
            let game = LibraryGame(folder: folder)
            games.append(game)
            folders[game.id] = GameFolder.scan(folder)
        }
        selection = max(0, games.count - 1)
        save()
    }

    func presentAddPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.folder] + GameFile.extensions.compactMap { .init(filenameExtension: $0) }
        panel.message = "Choose a folder holding one game’s NSP or XCI files (base game, plus update and DLC if you have them)"
        panel.prompt = "Add Game"
        if panel.runModal() == .OK { add(folders: panel.urls) }
    }

    func remove(_ id: UUID) {
        games.removeAll { $0.id == id }
        folders[id] = nil
        selection = min(selection, games.count)
        if case .game(let open) = sheet, open == id { sheet = nil }
        save()
    }

    func game(_ id: UUID) -> LibraryGame? { games.first { $0.id == id } }
    var selectedGame: LibraryGame? { games.indices.contains(selection) ? games[selection] : nil }

    func title(for game: LibraryGame) -> String {
        let folder = folders[game.id]
        return catalog[folder?.titleID]?.name ?? folder?.name ?? game.folder.lastPathComponent
    }

    /// Artwork: the built game's own icon, else nxnative's cover for tested games.
    func artwork(for game: LibraryGame) -> NSImage? {
        if let app = folders[game.id]?.latestMacApp {
            let icns = app.url.appendingPathComponent("Contents/Resources/AppIcon.icns")
            if let image = NSImage(contentsOf: icns) { return image }
        }
        if let art = catalog[folders[game.id]?.titleID]?.artwork { return NSImage(contentsOf: art) }
        return nil
    }

    private func save() {
        try? JSONEncoder().encode(games).write(to: libraryURL, options: .atomic)
    }

    // MARK: Navigation (keyboard and controller)

    func move(_ dx: Int, _ dy: Int) {
        if dy != 0 {
            let row = max(0, min(1, focusRow + dy))
            if row != focusRow { focusRow = row; click() }
            return
        }
        if focusRow == 0 {
            let next = max(0, min(games.count, selection + dx))
            if next != selection { selection = next; click() }
        } else {
            let next = max(0, min(HomeButton.allCases.count - 1, buttonSelection + dx))
            if next != buttonSelection { buttonSelection = next; click() }
        }
    }

    func activate() {
        guard sheet == nil else { return }
        play("Pop")
        if focusRow == 1 { HomeButton.allCases[buttonSelection].perform(self); return }
        if let game = selectedGame { sheet = .game(game.id) } else { presentAddPanel() }
    }

    /// Primary action straight from the home screen: play a built Mac app, else open the game's page.
    func quickPlay() {
        guard focusRow == 0, let game = selectedGame else { activate(); return }
        if let app = folders[game.id]?.latestMacApp { play("Pop"); NSWorkspace.shared.open(app.url) } else { activate() }
    }

    func click() { play("Tink", volume: 0.25) }

    func play(_ name: String, volume: Float = 0.5) {
        guard soundsEnabled, let sound = NSSound(named: name)?.copy() as? NSSound else { return }
        sound.volume = volume
        sound.play()
    }

    // MARK: Setup

    func check() async {
        isChecking = true
        requirements = await Toolchain.check(repo: repo, keys: keys)
        isChecking = false
        catalog = Catalog(repo: repo)
    }

    func chooseKeys() {
        let panel = NSOpenPanel()
        panel.message = "Choose the prod.keys file you dumped from your own console"
        panel.prompt = "Use Keys"
        panel.allowsOtherFileTypes = true
        if panel.runModal() == .OK, let url = panel.url { keysPath = url.path }
    }

    func perform(_ requirement: Requirement) {
        guard let fix = requirement.fix, fixing == nil else { return }
        switch fix {
        case .chooseKeys: chooseKeys()
        case .openURL(let url): NSWorkspace.shared.open(url)
        case .terminal(let command): Self.openInTerminal(command)
        case .run(let commands): runFix(requirement.id, commands)
        }
    }

    /// Runs every automatic fix in dependency order (tools before the Python environment that uses them).
    func fixAll() {
        let order: [Requirement.ID] = [.nxnative, .brewTools, .dotnet, .python]
        let queue = order.compactMap { id in requirements.first { $0.id == id && $0.status == .missing } }
        Task {
            for requirement in queue {
                guard case .run(let commands)? = requirement.fix else { continue }
                let ok = await runFixAsync(requirement.id, commands)
                if !ok { break }
                await check()
            }
        }
    }

    private func runFix(_ id: Requirement.ID, _ commands: [[String]]) {
        Task { _ = await runFixAsync(id, commands); await check() }
    }

    private func runFixAsync(_ id: Requirement.ID, _ commands: [[String]]) async -> Bool {
        fixing = id
        defer { fixing = nil }
        for command in commands {
            appendFix("$ " + command.map { $0.contains(" ") ? "'\($0)'" : $0 }.joined(separator: " ")
                .replacingOccurrences(of: NSHomeDirectory(), with: "~"))
            let status: Int32 = await withCheckedContinuation { continuation in
                do {
                    _ = try RunningProcess(command[0], Array(command.dropFirst()), onLine: { _, line in
                        Task { @MainActor in self.appendFix(line) }
                    }, onExit: { continuation.resume(returning: $0) })
                } catch {
                    Task { @MainActor in self.appendFix(error.localizedDescription) }
                    continuation.resume(returning: -1)
                }
            }
            if status != 0 {
                appendFix("✗ Failed (exit \(status))")
                play("Basso")
                return false
            }
        }
        appendFix("✓ Done")
        return true
    }

    private func appendFix(_ line: String) {
        fixLog.append(line)
        if fixLog.count > 2000 { fixLog.removeFirst(fixLog.count - 2000) }
    }

    static func openInTerminal(_ command: String) {
        let script = Paths.support.appendingPathComponent("install.command")
        let body = "#!/bin/bash\n\(command)\necho\necho 'Done. You can close this window and press Check Again in Cartridge.'\n"
        try? body.write(to: script, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        NSWorkspace.shared.open(script)
    }

    // MARK: nxnative updates

    func repoDescription() async -> String {
        guard FileManager.default.fileExists(atPath: repo.appendingPathComponent(".git").path) else { return "" }
        let log = await Shell.run("/usr/bin/git", ["-C", repo.path, "log", "-1", "--format=%cr"])
        return log.ok ? "Updated \(log.output.trimmingCharacters(in: .whitespacesAndNewlines))" : ""
    }

    func updateRepo() {
        guard !isUpdatingRepo, build == nil else { return }
        isUpdatingRepo = true
        Task {
            let result = await Shell.run("/usr/bin/git", ["-C", repo.path, "pull", "--ff-only"])
            isUpdatingRepo = false
            repoStatus = result.ok ? await repoDescription() : "Update failed"
            appendFix("$ git pull\n" + result.output)
            refresh()
            play(result.ok ? "Glass" : "Basso")
        }
    }

    // MARK: Building

    func startBuild(_ game: LibraryGame, options: BuildOptions) {
        guard build?.isRunning != true, let keys else { return }
        let session = BuildSession(gameID: game.id, title: title(for: game), folder: game.folder, options: options)
        build = session
        session.start(repo: repo, keys: keys) { [weak self] record in
            guard let self else { return }
            if let i = self.games.firstIndex(where: { $0.id == game.id }) {
                self.games[i].lastBuild = record
                self.save()
            }
            self.folders[game.id] = GameFolder.scan(game.folder)
            self.play(record.ok ? "Glass" : "Basso")
            Self.notify(title: record.ok ? "\(session.title) is ready" : "Build failed",
                        body: record.ok ? (options.platform == .macApp ? "Open it from Cartridge to play." : "The IPA is ready to sideload.")
                                        : (record.message ?? "See the log for details."))
        }
    }

    func cancelBuild() { build?.cancel() }

    func clearFinishedBuild() {
        if build?.isRunning == false { build = nil }
    }

    static func notify(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}

/// One run of nxnative's build script, driven through its JSON progress events.
@MainActor
@Observable
final class BuildSession {
    struct Stage: Identifiable {
        var id: Int { k }
        var k: Int
        var name: String
        var step = ""
        var fraction: Double?
        var eta: Double?
        var ok: Bool?
        var summary: String?
        var elapsed: Double = 0
    }
    enum State: Equatable { case running, succeeded(URL?), failed(String), cancelled }

    let gameID: UUID
    let title: String
    let folder: URL
    let options: BuildOptions
    let started = Date()

    private(set) var state = State.running
    private(set) var stages: [Stage] = []
    private(set) var stageCount = 0
    private(set) var messages: [(String, BuildEvent.Severity)] = []
    private(set) var log: [String] = []

    @ObservationIgnored private var process: RunningProcess?
    @ObservationIgnored private var activity: NSObjectProtocol?
    @ObservationIgnored private var cancelled = false

    var isRunning: Bool { state == .running }
    var current: Stage? { stages.last }

    var progress: Double {
        guard stageCount > 0 else { return 0 }
        let done = stages.filter { $0.ok != nil }.count
        let partial = stages.last.flatMap { $0.ok == nil ? $0.fraction : nil } ?? 0
        return min(1, (Double(done) + partial) / Double(stageCount))
    }

    init(gameID: UUID, title: String, folder: URL, options: BuildOptions) {
        self.gameID = gameID; self.title = title; self.folder = folder; self.options = options
    }

    func arguments(repo: URL, keys: URL) -> [String] {
        var args = [repo.appendingPathComponent("scripts/build_ipa_from_nsp.py").path, folder.path,
                    "-k", keys.path, "--progress", "json", "--platform", options.platform.rawValue]
        if let v = options.version { args += ["-p", "v\(v)"] }
        if !options.language.isEmpty { args += ["-l", options.language] }
        let name = options.appName.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { args += ["--app-name", name] }
        args.append(options.showFPS ? "--show-fps" : "--no-show-fps")
        args.append(options.keepExtracted ? "--keep-extracted" : "--no-keep-extracted")
        if options.allowDamaged { args.append("--allow-damaged") }
        return args
    }

    func start(repo: URL, keys: URL, completion: @escaping @MainActor (BuildRecord) -> Void) {
        // Builds take up to an hour: keep the Mac awake (the display may still sleep).
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                         reason: "Building \(title)")
        let args = arguments(repo: repo, keys: keys)
        log.append("$ python3 " + args.joined(separator: " ").replacingOccurrences(of: NSHomeDirectory(), with: "~"))
        do {
            process = try RunningProcess(Paths.venvPython.path, args, cwd: repo, onLine: { stream, line in
                Task { @MainActor in self.handle(line, stream) }
            }, onExit: { status in
                Task { @MainActor in self.finish(status, completion) }
            })
        } catch {
            finish(-1, completion, error: error.localizedDescription)
        }
    }

    func cancel() {
        guard isRunning else { return }
        cancelled = true
        process?.interrupt()
    }

    private func handle(_ line: String, _ stream: RunningProcess.Stream) {
        let event = stream == .stdout ? BuildEvent.parse(line) : .unparsed(line)
        switch event {
        case .stage(let k, let n, let name, let step):
            stageCount = max(stageCount, n)
            stages.append(Stage(k: k, name: name, step: step))
            log.append("▸ [\(k)/\(n)] \(name)")
        case .step(let k, _, let step):
            update(k) { $0.step = step }
        case .progress(let k, _, let step, let fraction, let eta, _):
            update(k) { $0.step = step; $0.fraction = fraction; $0.eta = eta }
        case .stageEnd(let k, let name, let ok, let summary, let elapsed):
            update(k) { $0.ok = ok; $0.summary = summary; $0.elapsed = elapsed; $0.fraction = 1 }
            log.append("\(ok ? "✓" : "✗") \(name)\(summary.map { ": \($0)" } ?? "") (\(Int(elapsed))s)")
        case .message(let text, let severity):
            messages.append((text, severity))
            log.append(text)
        case .unparsed(let text):
            if !text.isEmpty { log.append(text) }
        }
        if log.count > 5000 { log.removeFirst(log.count - 5000) }
        NSApp.dockTile.badgeLabel = isRunning ? "\(Int(progress * 100))%" : nil
    }

    private func update(_ k: Int, _ change: (inout Stage) -> Void) {
        if let i = stages.lastIndex(where: { $0.k == k }) { change(&stages[i]) }
    }

    private func finish(_ status: Int32, _ completion: @MainActor (BuildRecord) -> Void, error: String? = nil) {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        NSApp.dockTile.badgeLabel = nil
        let output = GameFolder.scan(folder).outputs.first {
            $0.date >= started.addingTimeInterval(-5) && $0.isMacApp == (options.platform == .macApp)
        }?.url
        let failure = error ?? messages.last { $0.1 == .error }?.0
        if cancelled {
            state = .cancelled
        } else if status == 0 {
            state = .succeeded(output)
        } else {
            state = .failed(failure ?? "nxnative stopped with exit code \(status).")
        }
        let ok = status == 0 && !cancelled
        completion(BuildRecord(date: Date(), platform: options.platform, ok: ok, output: ok ? output : nil,
                               message: cancelled ? "Stopped" : (ok ? nil : failure)))
    }
}
