import AppKit
import CartridgeCore
import SwiftUI

/// A game's page: its files, build options, live build progress and the built app.
struct GameSheet: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let gameID: UUID
    @State private var options = BuildOptions()
    @State private var showLog = false
    @State private var confirmRemove = false

    var body: some View {
        if let game = store.game(gameID), let folder = store.folders[gameID] {
            let session = store.build?.gameID == gameID ? store.build : nil
            VStack(spacing: 0) {
                header(game, folder)
                Divider()
                if let session, session.isRunning || showResult(session) {
                    BuildProgressView(session: session, showLog: $showLog)
                } else {
                    form(game, folder)
                }
                Divider()
                footer(game, folder, session)
            }
            .frame(width: 640, height: 640)
            .onAppear {
                options = store.defaultOptions
                if !store.isReady { options.platform = store.defaultOptions.platform }
            }
            .confirmationDialog("Remove \(store.title(for: game)) from Cartridge?", isPresented: $confirmRemove) {
                Button("Remove", role: .destructive) { store.remove(gameID); dismiss() }
            } message: {
                Text("Its files and any built apps stay in the folder.")
            }
        } else {
            ContentUnavailableView("Game not found", systemImage: "questionmark.folder")
                .frame(width: 400, height: 300)
        }
    }

    private func showResult(_ session: BuildSession) -> Bool {
        if case .failed = session.state { return true }
        if case .succeeded = session.state { return true }
        return false
    }

    // MARK: Header

    private func header(_ game: LibraryGame, _ folder: GameFolder) -> some View {
        let entry = store.catalog[folder.titleID]
        return HStack(alignment: .top, spacing: 18) {
            Group {
                if let art = store.artwork(for: game) {
                    Image(nsImage: art).resizable().scaledToFill()
                } else {
                    PlaceholderArt(title: store.title(for: game))
                }
            }
            .frame(width: 112, height: 112)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(color: .black.opacity(0.15), radius: 4, y: 2)

            VStack(alignment: .leading, spacing: 6) {
                Text(store.title(for: game)).font(.rounded(24, .bold)).lineLimit(2)
                if let id = folder.titleID {
                    Text(id).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                }
                HStack(spacing: 6) {
                    if entry != nil {
                        Chip(text: "Tested with nxnative", symbol: "checkmark.seal.fill", tint: .green)
                    } else if !store.catalog.entries.isEmpty {
                        Chip(text: "Untested: may not start", symbol: "flask.fill", tint: .orange)
                    }
                    Text(ByteCountFormatter.string(fromByteCount: folder.totalSize, countStyle: .file))
                        .font(.rounded(12, .medium)).foregroundStyle(.secondary)
                }
                if let id = folder.titleID, entry != nil {
                    Link("Game notes on GitHub", destination: URL(string: "https://github.com/seedds/nxnative/blob/main/dm/games/\(id)/README.md")!)
                        .font(.callout)
                }
            }
            Spacer()
        }
        .padding(22)
    }

    // MARK: Options

    private func form(_ game: LibraryGame, _ folder: GameFolder) -> some View {
        Form {
            if let record = game.lastBuild, !record.ok, store.build?.gameID != gameID {
                Section {
                    Label(record.message ?? "The last build failed.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }

            Section("Built") {
                if let app = folder.latestMacApp {
                    LabeledContent {
                        HStack {
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([app.url]) }
                            Button("Play") { NSWorkspace.shared.open(app.url) }.buttonStyle(.borderedProminent)
                        }
                    } label: {
                        Label { Text("Mac app").badge(Text(app.date, style: .date)) } icon: { Image(systemName: "macbook") }
                    }
                }
                if let ipa = folder.latestIPA {
                    LabeledContent {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([ipa.url]) }
                    } label: {
                        Label { Text("iPhone & iPad app").badge(Text(ipa.date, style: .date)) } icon: { Image(systemName: "iphone") }
                    }
                    Text("Install the IPA with your sideloading tool (AltStore, Sideloadly, LiveContainer…). Bigger games need the Increased Memory Limit capability.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if folder.outputs.isEmpty {
                    Text("Nothing built yet. The first build takes 30–60 minutes; later ones reuse what didn't change.")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Build") {
                Picker("Build for", selection: $options.platform) {
                    ForEach(BuildOptions.Platform.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                if folder.versions.count > 1 {
                    Picker("Version", selection: $options.version) {
                        Text("Newest (\(GameFolder.versionLabel(folder.versions.last!)))").tag(nil as Int?)
                        ForEach(folder.versions.reversed(), id: \.self) { Text(GameFolder.versionLabel($0)).tag($0 as Int?) }
                    }
                }
                Picker("Game language", selection: $options.language) {
                    ForEach(BuildOptions.languages, id: \.0) { Text($0.1).tag($0.0) }
                }
                TextField("App name", text: $options.appName, prompt: Text(store.title(for: game)))
                Toggle("Show frame rate", isOn: $options.showFPS)
                Toggle("Keep extracted files (faster rebuilds)", isOn: $options.keepExtracted)
                DisclosureGroup("Advanced") {
                    Toggle("Continue with damaged files", isOn: $options.allowDamaged)
                        .help("Write files that fail the integrity check as read, instead of stopping")
                }
            }

            Section("Files") {
                ForEach(folder.files, id: \.url) { file in
                    LabeledContent {
                        Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)).monospacedDigit()
                    } label: {
                        Label(file.url.lastPathComponent, systemImage: icon(file.kind)).lineLimit(1).truncationMode(.middle)
                    }
                }
                if folder.base == nil {
                    Label("No base game found. Add the base game’s NSP or XCI to this folder.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                diskSpace(folder)
            }
        }
        .formStyle(.grouped)
    }

    private func icon(_ kind: GameFile.Kind) -> String {
        switch kind {
        case .base: "opticaldisc"
        case .update: "arrow.up.circle"
        case .dlc: "puzzlepiece.extension"
        case .unknown: "doc"
        }
    }

    @ViewBuilder
    private func diskSpace(_ folder: GameFolder) -> some View {
        let free = (try? folder.url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
        let enough = free >= folder.requiredSpace
        LabeledContent("Free space") {
            Text("\(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) of ~\(ByteCountFormatter.string(fromByteCount: folder.requiredSpace, countStyle: .file)) needed")
                .foregroundStyle(enough ? Color.secondary : Color.red)
        }
    }

    // MARK: Footer

    private func footer(_ game: LibraryGame, _ folder: GameFolder, _ session: BuildSession?) -> some View {
        HStack {
            Button("Remove…", role: .destructive) { confirmRemove = true }
                .disabled(session?.isRunning == true)
            Spacer()
            if !store.isReady {
                Button("Finish Setup…") { store.sheet = .setup }
            }
            Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            if let session, session.isRunning {
                Button("Stop Build", role: .destructive) { store.cancelBuild() }
            } else if let session, showResult(session) {
                Button("Done") { store.clearFinishedBuild() }.keyboardShortcut(.defaultAction)
            } else {
                let busy = store.build?.isRunning == true
                Button(folder.outputs.isEmpty ? "Build" : "Rebuild") { store.startBuild(game, options: options) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!store.isReady || busy || folder.base == nil)
                    .help(busy ? "Another game is building" : !store.isReady ? "Finish setup first" : "")
            }
        }
        .padding(16)
    }
}

/// Live view of a running (or just finished) build.
struct BuildProgressView: View {
    @Environment(Store.self) private var store
    let session: BuildSession
    @Binding var showLog: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch session.state {
            case .running:
                HStack {
                    Text(session.current.map { "\($0.name.capitalized)" } ?? "Starting…").font(.rounded(18, .semibold))
                    Spacer()
                    Text("\(Int(session.progress * 100))%").font(.rounded(18, .bold)).monospacedDigit()
                }
                ProgressView(value: session.progress).tint(.focus)
                HStack {
                    if let step = session.current?.step, !step.isEmpty { Text(step).lineLimit(1) }
                    Spacer()
                    if let eta = session.current?.eta, eta > 0 { Text("about \(Self.duration(eta)) left in this step") }
                    Text("· \(Self.duration(Date().timeIntervalSince(session.started))) elapsed")
                }
                .font(.callout).foregroundStyle(.secondary)
            case .succeeded(let output):
                Label("\(session.title) is ready", systemImage: "checkmark.circle.fill")
                    .font(.rounded(20, .semibold)).foregroundStyle(.green)
                if let output {
                    HStack {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([output]) }
                        if output.pathExtension == "app" {
                            Button("Play Now") { NSWorkspace.shared.open(output) }.buttonStyle(.borderedProminent)
                        }
                    }
                }
            case .failed(let message):
                Label("The build stopped", systemImage: "xmark.octagon.fill")
                    .font(.rounded(20, .semibold)).foregroundStyle(.red)
                Text(message).textSelection(.enabled)
            case .cancelled:
                Label("Build stopped", systemImage: "stop.circle").font(.rounded(20, .semibold))
            }

            List {
                ForEach(session.stages.reversed()) { stage in
                    HStack {
                        Group {
                            if let ok = stage.ok {
                                Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundStyle(ok ? .green : .red)
                            } else {
                                ProgressView().controlSize(.small)
                            }
                        }
                        .frame(width: 20)
                        Text("\(stage.k). \(stage.name.capitalized)")
                        if let summary = stage.summary, !summary.isEmpty {
                            Text(summary).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if stage.ok != nil { Text(Self.duration(stage.elapsed)).foregroundStyle(.secondary).monospacedDigit() }
                    }
                }
                if session.stageCount > session.stages.count {
                    Text("\(session.stageCount - session.stages.count) more steps").foregroundStyle(.tertiary)
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .frame(maxHeight: showLog ? 120 : .infinity)

            DisclosureGroup("Log", isExpanded: $showLog) {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(session.log.suffix(800).joined(separator: "\n"))
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id("end")
                    }
                    .frame(height: 180)
                    .background(.background.secondary)
                    .onChange(of: session.log.count) { proxy.scrollTo("end", anchor: .bottom) }
                }
            }
        }
        .padding(22)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds)
        return s < 60 ? "\(s)s" : s < 3600 ? "\(s / 60)m \(s % 60)s" : "\(s / 3600)h \(s % 3600 / 60)m"
    }
}
