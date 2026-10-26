import AppKit
import CartridgeCore
import CryptoKit
import Observation

/// Checks GitHub releases for a newer Cartridge, shows their changelogs, and installs an update in place.
@MainActor
@Observable
final class Updater {
    static let repo = "rbxrootx/cartridge"

    enum State: Equatable {
        case idle, checking, upToDate, available, downloading, installing
        case failed(String)
    }

    private(set) var state = State.idle
    /// Releases newer than this copy, newest first.
    private(set) var updates: [Release] = []
    /// Release notes of the running version, shown once after updating.
    private(set) var whatsNew: Release?
    private(set) var lastChecked: Date?

    var automatic: Bool { didSet { defaults.set(automatic, forKey: "autoUpdate") } }
    @ObservationIgnored private var skippedVersion: String? {
        get { defaults.string(forKey: "skippedVersion") }
        set { defaults.set(newValue, forKey: "skippedVersion") }
    }
    @ObservationIgnored private let defaults = UserDefaults.standard

    let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    var latest: Release? { updates.first }

    init() {
        automatic = defaults.object(forKey: "autoUpdate") as? Bool ?? true
    }

    /// Called at launch: show what's new after an update, then check for newer versions (daily).
    func launch() {
        let previous = defaults.string(forKey: "lastRunVersion")
        defaults.set(currentVersion, forKey: "lastRunVersion")
        Task {
            if let previous, Version.isNewer(currentVersion, than: previous) {
                whatsNew = try? await fetchReleases().first { Version.compare($0.version, currentVersion) == .orderedSame }
            }
            guard automatic else { return }
            await check(userInitiated: false)
            #if DEBUG
            // End-to-end test hooks; compiled out of release builds.
            let env = ProcessInfo.processInfo.environment
            if env["CARTRIDGE_DEBUG_SHEET"] == "update", latest != nil { Store.shared.sheet = .update }
            if env["CARTRIDGE_DEBUG_AUTOINSTALL"] == "1", latest != nil {
                try? await Task.sleep(for: .seconds(4))
                installLatest()
            }
            #endif
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(24 * 3600))
                if automatic { await check(userInitiated: false) }
            }
        }
    }

    func check(userInitiated: Bool) async {
        guard state != .downloading, state != .installing else { return }
        state = .checking
        do {
            var found = Version.updates(from: try await fetchReleases(), current: currentVersion)
            // A skipped version stays hidden from automatic checks until something newer comes out.
            if !userInitiated, let skipped = skippedVersion, let newest = found.first,
               Version.compare(newest.version, skipped) != .orderedDescending {
                found = []
            }
            updates = found
            state = found.isEmpty ? .upToDate : .available
        } catch {
            state = userInitiated ? .failed("Couldn’t check for updates: \(error.localizedDescription)") : .idle
        }
        lastChecked = Date()
    }

    func skipLatest() {
        skippedVersion = latest?.version
        updates = []
        state = .upToDate
    }

    func dismissWhatsNew() { whatsNew = nil }

    private func fetchReleases() async throws -> [Release] {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases?per_page=30")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Cartridge/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try Release.decodeList(data)
    }

    // MARK: Installing

    /// Downloads the latest release, verifies it, swaps it in for this copy and relaunches.
    func installLatest() {
        guard let release = latest, let zip = release.asset(named: "Cartridge.zip") else {
            state = .failed("This release has no Cartridge.zip to install.")
            return
        }
        let destination = Bundle.main.bundleURL
        guard FileManager.default.isWritableFile(atPath: destination.deletingLastPathComponent().path) else {
            state = .failed("Cartridge can’t replace itself in \(destination.deletingLastPathComponent().path). Move it to Applications and try again.")
            return
        }
        state = .downloading
        Task {
            do {
                let newApp = try await download(zip, checksum: release.asset(named: "Cartridge.zip.sha256"))
                state = .installing
                try relaunch(replacing: destination, with: newApp)
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    private func download(_ asset: Release.Asset, checksum: Release.Asset?) async throws -> URL {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("CartridgeUpdate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let (file, _) = try await URLSession.shared.download(from: asset.browserDownloadURL)
        let zip = work.appendingPathComponent("Cartridge.zip")
        try FileManager.default.moveItem(at: file, to: zip)

        // The release publishes "<sha256>  Cartridge.zip" beside the zip.
        if let checksum {
            let (data, _) = try await URLSession.shared.data(from: checksum.browserDownloadURL)
            let expected = String(decoding: data, as: UTF8.self).split(separator: " ").first.map(String.init)?.lowercased()
            let actual = SHA256.hash(data: try Data(contentsOf: zip)).map { String(format: "%02x", $0) }.joined()
            guard expected == actual else { throw UpdateError("The download’s checksum doesn’t match. Nothing was changed.") }
        }

        guard await Shell.run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path]).ok else {
            throw UpdateError("Couldn’t unpack the update.")
        }
        let app = work.appendingPathComponent("Cartridge.app")
        let bundleID = Bundle(url: app)?.bundleIdentifier
        guard bundleID == Bundle.main.bundleIdentifier else { throw UpdateError("The download isn’t a Cartridge app.") }
        guard await Shell.run("/usr/bin/codesign", ["--verify", "--strict", app.path]).ok else {
            throw UpdateError("The update’s code signature is invalid. Nothing was changed.")
        }
        return app
    }

    /// A helper script waits for this process to quit, swaps the bundles (restoring the old one on failure)
    /// and opens the new version.
    private func relaunch(replacing destination: URL, with newApp: URL) throws {
        let script = """
        #!/bin/sh
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
        DEST="\(destination.path)"
        NEW="\(newApp.path)"
        rm -rf "$DEST.previous"
        if mv "$DEST" "$DEST.previous" && mv "$NEW" "$DEST"; then
          rm -rf "$DEST.previous"
        else
          [ -d "$DEST" ] || mv "$DEST.previous" "$DEST"
        fi
        xattr -dr com.apple.quarantine "$DEST" 2>/dev/null
        open "$DEST"
        """
        let url = newApp.deletingLastPathComponent().appendingPathComponent("relaunch.sh")
        try script.write(to: url, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [url.path]
        try process.run()
        // AppKit won't quit while a sheet is attached, so close it first; exit outright if anything still blocks.
        Store.shared.sheet = nil
        Store.shared.cancelBuild()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { NSApp.terminate(nil) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { exit(0) }
    }

    struct UpdateError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
