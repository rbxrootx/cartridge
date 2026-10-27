import CartridgeCore
import SwiftUI

struct SetupView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "wrench.and.screwdriver.fill")
                    .font(.system(size: 26)).foregroundStyle(.white)
                    .frame(width: 52, height: 52).background(Color.green.gradient, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("Setup").font(.rounded(24, .bold))
                    Text(store.isReady ? "Everything’s ready. Add a game and build it."
                                       : "Cartridge installs nxnative and the tools it needs. You only do this once.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(22)

            Form {
                Section {
                    ForEach(store.requirements) { requirement in
                        RequirementRow(requirement: requirement)
                    }
                    if store.requirements.isEmpty {
                        HStack { ProgressView().controlSize(.small); Text("Checking…") }
                    }
                }
                if !store.fixLog.isEmpty {
                    Section("Output") {
                        ScrollViewReader { proxy in
                            ScrollView {
                                Text(store.fixLog.suffix(400).joined(separator: "\n"))
                                    .font(.system(size: 11, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id("end")
                            }
                            .frame(height: 150)
                            .onChange(of: store.fixLog.count) { proxy.scrollTo("end", anchor: .bottom) }
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Button("Check Again") { Task { await store.check() } }
                    .disabled(store.isChecking || store.fixing != nil)
                if store.isChecking || store.fixing != nil { ProgressView().controlSize(.small) }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                let automatic = store.requirements.filter {
                    if case .run? = $0.fix { return $0.status == .missing } else { return false }
                }
                Button(automatic.count > 1 ? "Install All (\(automatic.count))" : "Install") { store.fixAll() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(automatic.isEmpty || store.fixing != nil)
            }
            .padding(16)
        }
        .frame(width: 620, height: 640)
    }
}

private struct RequirementRow: View {
    @Environment(Store.self) private var store
    let requirement: Requirement

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Group {
                switch requirement.status {
                case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .missing: Image(systemName: "circle.dashed").foregroundStyle(.orange)
                case .unsupported: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                }
            }
            .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(requirement.title).font(.headline)
                Text(requirement.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if store.fixing == requirement.id {
                ProgressView().controlSize(.small)
            } else if requirement.fix != nil && (requirement.status != .ok || requirement.id == .keys),
                      let label = requirement.fixLabel {
                Button(label) { store.perform(requirement) }
                    .disabled(store.fixing != nil)
            }
        }
        .padding(.vertical, 2)
    }
}

struct HelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("How it works").font(.rounded(24, .bold))
                    step(1, "Set up once", "Cartridge downloads the open-source nxnative project and installs the tools it needs.")
                    step(2, "Add your game", "A folder with the base game’s NSP or XCI, plus its update and DLC if you have them, dumped from your own console.")
                    step(3, "Build", "nxnative turns the game into a Mac app you can play, or an IPA to sideload to an iPhone or iPad. The first build takes 30–60 minutes.")
                    step(4, "Play", "Press A (or Return) on a ready game. Saves live in ~/Library/Application Support/nxnative.")

                    Divider()
                    Text("Legal").font(.rounded(20, .bold))
                    Text("""
                    Cartridge is a front-end for nxnative. It doesn’t include, download or help you find games, firmware or keys, and never uploads anything. Use only games you own and keys from your own console. The rules on dumping your own games and keys differ by country, so check the law where you live.

                    Cartridge and nxnative aren’t affiliated with or endorsed by Nintendo or any game publisher. Game names and artwork belong to their owners; artwork is shown from your local nxnative copy.
                    """)
                    .foregroundStyle(.secondary)

                    Text("Credits").font(.rounded(20, .bold))
                    Text("nxnative by seedds and contributors (MIT), building on d2r-mobile, Ryujinx, Atmosphère, LibHac, SPIRV-Cross and others.")
                        .foregroundStyle(.secondary)
                    Link("nxnative on GitHub", destination: URL(string: "https://github.com/seedds/nxnative")!)
                }
                .padding(26)
            }
            Divider()
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }.padding(16)
        }
        .frame(width: 560, height: 620)
    }

    private func step(_ n: Int, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(n)").font(.rounded(16, .bold)).foregroundStyle(.white)
                .frame(width: 30, height: 30).background(Color.focus.gradient, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct SettingsView: View {
    @Environment(Store.self) private var store

    var body: some View {
        @Bindable var store = store
        Form {
            Section("nxnative") {
                Picker("Location", selection: Binding(
                    get: { store.customRepoPath == nil ? 0 : 1 },
                    set: { if $0 == 0 { store.customRepoPath = nil } else { chooseRepo() } })) {
                    Text("Managed by Cartridge").tag(0)
                    Text(store.customRepoPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Custom…").tag(1)
                }
                LabeledContent("Version", value: store.repoStatus.isEmpty ? "Not downloaded" : store.repoStatus)
                Button("Update Now") { store.updateRepo() }.disabled(store.isUpdatingRepo)
            }
            Section("Keys") {
                LabeledContent("prod.keys") {
                    Text(store.keysPath.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "Not chosen")
                        .lineLimit(1).truncationMode(.head)
                }
                Button("Choose…") { store.chooseKeys() }
            }
            Section("New builds") {
                Picker("Build for", selection: $store.defaultOptions.platform) {
                    ForEach(BuildOptions.Platform.allCases) { Text($0.label).tag($0) }
                }
                Picker("Game language", selection: $store.defaultOptions.language) {
                    ForEach(BuildOptions.languages, id: \.0) { Text($0.1).tag($0.0) }
                }
                Toggle("Show frame rate", isOn: $store.defaultOptions.showFPS)
                Toggle("Keep extracted files", isOn: $store.defaultOptions.keepExtracted)
            }
            Section("Home") {
                Toggle("Menu sounds", isOn: $store.soundsEnabled)
            }
            Section("Updates") {
                LabeledContent("Cartridge", value: "Version \(store.updater.currentVersion)")
                Toggle("Check for updates automatically", isOn: Binding(get: { store.updater.automatic },
                                                                         set: { store.updater.automatic = $0 }))
                HStack {
                    Button("Check Now") { Task { await store.updater.check(userInitiated: true); showUpdateIfAny() } }
                        .disabled(store.updater.state == .checking)
                    Spacer()
                    switch store.updater.state {
                    case .checking: ProgressView().controlSize(.small)
                    case .upToDate: Text("Up to date").foregroundStyle(.secondary)
                    case .available: Button("Version \(store.updater.latest?.version ?? "") available…") { store.sheet = .update }
                    case .failed(let m): Text(m).foregroundStyle(.red).lineLimit(1)
                    default: EmptyView()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func showUpdateIfAny() {
        if store.updater.latest != nil { store.sheet = .update }
    }

    private func chooseRepo() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose your nxnative folder"
        if panel.runModal() == .OK, let url = panel.url { store.customRepoPath = url.path }
    }
}

/// Shown when a built game quits right after launching.
struct LaunchFailedView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let failure = store.launchFailure {
                Label("\(failure.title) stopped", systemImage: "xmark.octagon.fill")
                    .font(.rounded(22, .bold)).foregroundStyle(.red)
                if let hint = failure.hint {
                    Text(hint).font(.body).fixedSize(horizontal: false, vertical: true)
                }
                Text("The last lines of the game’s log:").font(.callout).foregroundStyle(.secondary)
                ScrollView {
                    Text(failure.logTail)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
                HStack {
                    if let log = failure.logURL {
                        Button("Show Full Log") { NSWorkspace.shared.activateFileViewerSelecting([log]) }
                    }
                    Spacer()
                    Button("OK") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(22)
        .frame(width: 600, height: 520)
    }
}
