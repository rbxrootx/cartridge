import Foundation

/// Everything nxnative needs, how to check it, and how to fix it.
public struct Requirement: Identifiable, Hashable, Sendable {
    public enum ID: String, CaseIterable, Sendable {
        case appleSilicon, xcode, homebrew, brewTools, dotnet, python, nxnative, keys
    }
    public enum Status: Hashable, Sendable { case ok, missing, unsupported }

    /// How to fix a missing requirement.
    public enum Fix: Hashable, Sendable {
        /// Commands the launcher runs itself, showing their output.
        case run([[String]])
        /// Needs an administrator password: opens Terminal with the command.
        case terminal(String)
        case openURL(URL)
        case chooseKeys
    }

    public var id: ID
    public var title: String
    public var detail: String
    public var status: Status
    public var fix: Fix?
    public var fixLabel: String?
}

public enum Toolchain {
    public static let brewFormulae = ["xcodegen", "zstd", "spirv-cross", "glslang", "python@3.13"]
    static let brewExecutables = ["xcodegen": "xcodegen", "zstd": "zstd", "spirv-cross": "spirv-cross",
                                  "glslang": "glslangValidator", "python@3.13": "python3.13"]
    public static let pythonPackages = ["lz4", "capstone", "fonttools", "backports.zstd; python_version < '3.14'", "nsz"]
    public static let repoURL = URL(string: "https://github.com/seedds/nxnative.git")!

    public static var brewPath: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Checks everything. `repo` is the nxnative checkout in use, `keys` the user's prod.keys.
    public static func check(repo: URL, keys: URL?) async -> [Requirement] {
        async let silicon = checkAppleSilicon()
        async let xcode = checkXcode()
        async let dotnet = checkDotnet()
        async let python = checkPython()
        let brew = checkHomebrew()
        let tools = checkBrewTools()
        return [await silicon, await xcode, brew, tools, await dotnet, await python, checkRepo(repo), checkKeys(keys)]
    }

    static func checkAppleSilicon() async -> Requirement {
        let arch = await Shell.run("/usr/bin/uname", ["-m"]).output.trimmingCharacters(in: .whitespacesAndNewlines)
        let ok = arch == "arm64"
        return Requirement(id: .appleSilicon, title: "Apple silicon Mac",
                           detail: ok ? "Games can run on this Mac." : "This Mac can build iPhone/iPad apps, but Mac apps need Apple silicon.",
                           status: ok ? .ok : .unsupported)
    }

    static func checkXcode() async -> Requirement {
        let path = await Shell.run("/usr/bin/xcode-select", ["-p"]).output.trimmingCharacters(in: .whitespacesAndNewlines)
        let version = await Shell.run("/usr/bin/xcodebuild", ["-version"])
        let ok = path.contains(".app/Contents/Developer") && version.ok
        return Requirement(id: .xcode, title: "Xcode",
                           detail: ok ? (version.output.split(separator: "\n").first.map(String.init) ?? "Installed")
                                      : "The full Xcode app is needed (not just the command line tools).",
                           status: ok ? .ok : .missing,
                           fix: ok ? nil : .openURL(URL(string: "macappstore://apps.apple.com/app/id497799835")!),
                           fixLabel: "Get Xcode")
    }

    static func checkHomebrew() -> Requirement {
        let ok = brewPath != nil
        return Requirement(id: .homebrew, title: "Homebrew",
                           detail: ok ? "Installed" : "The package manager used to install the build tools. Its installer asks for your password.",
                           status: ok ? .ok : .missing,
                           fix: ok ? nil : .terminal(#"/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)""#),
                           fixLabel: "Install in Terminal…")
    }

    static func checkBrewTools() -> Requirement {
        let missing = brewFormulae.filter { Shell.find([brewExecutables[$0] ?? $0]) == nil }
        let ok = missing.isEmpty
        return Requirement(id: .brewTools, title: "Build tools",
                           detail: ok ? "xcodegen, zstd, SPIRV-Cross, glslang, Python 3.13" : "Missing: \(missing.joined(separator: ", "))",
                           status: ok ? .ok : .missing,
                           fix: ok || brewPath == nil ? nil : .run([[brewPath!, "install"] + missing]),
                           fixLabel: "Install")
    }

    static func checkDotnet() async -> Requirement {
        var sdks = ""
        if let dotnet = Shell.find(["dotnet"]) {
            sdks = await Shell.run(dotnet, ["--list-sdks"]).output
        }
        let ok = sdks.split(separator: "\n").contains { $0.hasPrefix("10.") }
        let installer = Paths.support.appendingPathComponent("dotnet-install.sh").path
        return Requirement(id: .dotnet, title: ".NET SDK 10",
                           detail: ok ? "Installed" : "Used to read game files. Installed into ~/.dotnet with Microsoft's official script (no password needed).",
                           status: ok ? .ok : .missing,
                           fix: ok ? nil : .run([
                               ["/usr/bin/curl", "-fsSL", "https://dot.net/v1/dotnet-install.sh", "-o", installer],
                               ["/bin/bash", installer, "--channel", "10.0", "--install-dir", Paths.dotnetDir.path],
                           ]),
                           fixLabel: "Install")
    }

    static func checkPython() async -> Requirement {
        let python = Paths.venvPython.path
        var ok = false
        if FileManager.default.isExecutableFile(atPath: python) {
            let probe = """
            import sys, importlib.util as u
            mods = ['lz4', 'capstone', 'fontTools'] + (['backports.zstd'] if sys.version_info < (3, 14) else [])
            missing = [m for m in mods if u.find_spec(m) is None]
            print('missing:' + ','.join(missing)); sys.exit(1 if missing or sys.version_info < (3, 10) else 0)
            """
            ok = await Shell.run(python, ["-c", probe]).ok
        }
        let basePython = Shell.find(["python3.13", "python3.14", "python3.12"]) ?? "/opt/homebrew/bin/python3"
        let pip = Paths.venv.appendingPathComponent("bin/pip").path
        return Requirement(id: .python, title: "Python packages",
                           detail: ok ? "lz4, capstone, fontTools, nsz in Cartridge's own Python environment"
                                      : "A private Python environment for nxnative (doesn't touch your system Python).",
                           status: ok ? .ok : .missing,
                           fix: ok ? nil : .run([
                               [basePython, "-m", "venv", "--clear", Paths.venv.path],
                               [pip, "install", "--upgrade", "pip"],
                               [pip, "install"] + pythonPackages,
                           ]),
                           fixLabel: "Set Up")
    }

    static func checkRepo(_ repo: URL) -> Requirement {
        let ok = FileManager.default.fileExists(atPath: repo.appendingPathComponent("scripts/build_ipa_from_nsp.py").path)
        let isManaged = repo.standardizedFileURL == Paths.managedRepo.standardizedFileURL
        return Requirement(id: .nxnative, title: "nxnative",
                           detail: ok ? repo.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
                                      : "Downloads the open-source nxnative project from GitHub.",
                           status: ok ? .ok : .missing,
                           fix: ok || !isManaged ? nil : .run([["/usr/bin/git", "clone", "--depth", "1", repoURL.absoluteString, repo.path]]),
                           fixLabel: "Download")
    }

    static func checkKeys(_ keys: URL?) -> Requirement {
        let state = keys.map(KeysFile.validate) ?? .notChosen
        return Requirement(id: .keys, title: "Your console keys",
                           detail: state.description,
                           status: state == .valid ? .ok : .missing,
                           fix: .chooseKeys, fixLabel: keys == nil ? "Choose…" : "Change…")
    }
}

/// The user's prod.keys. Only its shape is checked: the launcher never displays, copies or uploads key values.
public enum KeysFile {
    public enum State: Equatable, Sendable, CustomStringConvertible {
        case notChosen, missing, invalid, valid
        public var description: String {
            switch self {
            case .notChosen: "Choose the prod.keys you dumped from your own console."
            case .missing: "The chosen keys file can't be found."
            case .invalid: "This doesn't look like a prod.keys file."
            case .valid: "prod.keys from your console (stays where it is; never copied or shared)"
            }
        }
    }

    public static func validate(_ url: URL) -> State {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .missing }
        defer { try? handle.close() }
        let head = String(decoding: (try? handle.read(upToCount: 64 * 1024)) ?? Data(), as: UTF8.self)
        let lines = head.split(separator: "\n").filter { $0.contains(/^\s*[a-z0-9_]+\s*=\s*[0-9A-Fa-f]{16,}\s*$/) }
        return lines.count >= 5 ? .valid : .invalid
    }
}
