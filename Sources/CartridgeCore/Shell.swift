import Foundation

/// Paths the launcher and nxnative need. GUI apps don't inherit the shell's PATH.
public enum Paths {
    public static let support: URL = {
        var url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cartridge", isDirectory: true)
        #if DEBUG
        // Screenshots and tests use an isolated folder; compiled out of release builds.
        if let dir = ProcessInfo.processInfo.environment["CARTRIDGE_DEBUG_SUPPORT"] { url = URL(fileURLWithPath: dir) }
        #endif
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// nxnative checkout managed by the launcher (unless the user points it at their own).
    public static var managedRepo: URL { support.appendingPathComponent("nxnative", isDirectory: true) }
    /// Private Python environment with nxnative's packages, so nothing system-wide is touched.
    public static var venv: URL { support.appendingPathComponent("python", isDirectory: true) }
    public static var venvPython: URL { venv.appendingPathComponent("bin/python3") }
    /// Where Microsoft's installer puts .NET without admin rights (nxnative looks here too).
    public static var dotnetDir: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".dotnet") }

    public static var toolPATH: String {
        [venv.appendingPathComponent("bin").path, "/opt/homebrew/bin", "/usr/local/bin", dotnetDir.path,
         "/usr/local/share/dotnet", "/usr/bin", "/bin", "/usr/sbin", "/sbin"].joined(separator: ":")
    }

    public static func environment(extra: [String: String] = [:]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = toolPATH
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        env["NONINTERACTIVE"] = "1"
        env["DOTNET_CLI_TELEMETRY_OPTOUT"] = "1"
        env["PYTHONUNBUFFERED"] = "1"
        if FileManager.default.fileExists(atPath: dotnetDir.appendingPathComponent("dotnet").path) {
            env["DOTNET_ROOT"] = dotnetDir.path
        }
        return env.merging(extra) { $1 }
    }
}

public struct CommandResult: Sendable {
    public var status: Int32
    public var output: String
    public var ok: Bool { status == 0 }
}

/// A running child process whose output arrives line by line.
public final class RunningProcess: @unchecked Sendable {
    public enum Stream: Sendable { case stdout, stderr }

    private let process = Process()
    private let lock = NSLock()
    private var buffers: [Stream: Data] = [.stdout: Data(), .stderr: Data()]

    public var pid: Int32 { process.processIdentifier }

    public init(_ executable: String, _ arguments: [String], cwd: URL? = nil, environment: [String: String] = Paths.environment(),
                onLine: @escaping @Sendable (Stream, String) -> Void,
                onExit: @escaping @Sendable (Int32) -> Void) throws {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        if let cwd { process.currentDirectoryURL = cwd }
        process.standardInput = FileHandle.nullDevice

        for (stream, pipe) in [(Stream.stdout, Pipe()), (Stream.stderr, Pipe())] {
            if stream == .stdout { process.standardOutput = pipe } else { process.standardError = pipe }
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard let self else { return }
                if data.isEmpty { handle.readabilityHandler = nil; self.flush(stream, onLine); return }
                self.consume(data, stream, onLine)
            }
        }
        process.terminationHandler = { [weak self] p in
            // Give the pipes a moment to drain before reporting the exit.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                if let self { self.flush(.stdout, onLine); self.flush(.stderr, onLine) }
                onExit(p.terminationStatus)
            }
        }
        try process.run()
    }

    private func consume(_ data: Data, _ stream: Stream, _ onLine: (Stream, String) -> Void) {
        lock.lock()
        buffers[stream, default: Data()].append(data)
        var lines = [String]()
        while let nl = buffers[stream]!.firstIndex(of: 0x0A) {
            let line = buffers[stream]![buffers[stream]!.startIndex..<nl]
            lines.append(String(decoding: line, as: UTF8.self).replacingOccurrences(of: "\r", with: ""))
            buffers[stream]!.removeSubrange(buffers[stream]!.startIndex...nl)
        }
        lock.unlock()
        lines.forEach { onLine(stream, $0) }
    }

    private func flush(_ stream: Stream, _ onLine: (Stream, String) -> Void) {
        lock.lock()
        let rest = buffers[stream] ?? Data()
        buffers[stream] = Data()
        lock.unlock()
        if !rest.isEmpty { onLine(stream, String(decoding: rest, as: UTF8.self)) }
    }

    /// Interrupts the process and everything it started (dotnet, xcodebuild, …), like Ctrl-C in a terminal.
    public func interrupt() {
        for pid in Self.descendants(of: process.processIdentifier) + [process.processIdentifier] {
            kill(pid, SIGINT)
        }
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, self.process.isRunning else { return }
            for p in Self.descendants(of: pid) + [pid] { kill(p, SIGTERM) }
        }
    }

    static func descendants(of pid: Int32) -> [Int32] {
        let result = Shell.runSync("/usr/bin/pgrep", ["-P", String(pid)])
        let children = result.output.split(separator: "\n").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
        return children.flatMap { descendants(of: $0) + [$0] }
    }
}

public enum Shell {
    /// Runs a command to completion, returning combined output.
    public static func run(_ executable: String, _ arguments: [String], cwd: URL? = nil,
                           environment: [String: String] = Paths.environment()) async -> CommandResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: runSync(executable, arguments, cwd: cwd, environment: environment))
            }
        }
    }

    public static func runSync(_ executable: String, _ arguments: [String], cwd: URL? = nil,
                               environment: [String: String] = Paths.environment()) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        if let cwd { process.currentDirectoryURL = cwd }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return CommandResult(status: -1, output: error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }

    /// First existing executable among candidates, or nil.
    public static func find(_ names: [String]) -> String? {
        for dir in Paths.toolPATH.split(separator: ":") {
            for name in names {
                let path = "\(dir)/\(name)"
                if FileManager.default.isExecutableFile(atPath: path) { return path }
            }
        }
        return nil
    }
}
