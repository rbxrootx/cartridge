import AppKit
import CartridgeCore
import IOKit.ps
import SwiftUI

extension Color {
    /// Selection highlight: a bright cyan, like a console menu's focus ring.
    static let focus = Color(red: 0.0, green: 0.78, blue: 0.93)
    static let homeBackground = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.17, alpha: 1) : NSColor(white: 0.93, alpha: 1)
    })
    static let tileBackground = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.24, alpha: 1) : .white
    })
}

extension Font {
    static func rounded(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

enum HomeButton: Int, CaseIterable, Identifiable {
    case add, setup, keys, update, folder, settings, help
    var id: Int { rawValue }

    var title: String {
        switch self {
        case .add: "Add Game"
        case .setup: "Setup"
        case .keys: "Keys"
        case .update: "Update nxnative"
        case .folder: "Show in Finder"
        case .settings: "Settings"
        case .help: "Help & Legal"
        }
    }
    var symbol: String {
        switch self {
        case .add: "plus"
        case .setup: "wrench.and.screwdriver.fill"
        case .keys: "key.fill"
        case .update: "arrow.triangle.2.circlepath"
        case .folder: "folder.fill"
        case .settings: "gearshape.fill"
        case .help: "questionmark"
        }
    }
    var tint: Color {
        switch self {
        case .add: .focus
        case .setup: .green
        case .keys: .red
        case .update: .blue
        case .folder: .orange
        case .settings: .gray
        case .help: .purple
        }
    }

    @MainActor func perform(_ store: Store) {
        switch self {
        case .add: store.presentAddPanel()
        case .setup: store.sheet = .setup
        case .keys: store.chooseKeys()
        case .update: store.updateRepo()
        case .folder:
            if let game = store.selectedGame { NSWorkspace.shared.activateFileViewerSelecting([game.folder]) }
            else { NSWorkspace.shared.open(store.repo) }
        case .settings: NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        case .help: store.sheet = .help
        }
    }
}

struct HomeView: View {
    @Environment(Store.self) private var store
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            TopBar()
            if store.updater.latest != nil {
                UpdateBanner()
            } else if !store.requirements.isEmpty && !store.isReady {
                SetupBanner()
            }
            Spacer(minLength: 12)
            GameRow()
            Spacer(minLength: 20)
            ButtonRow()
            Spacer(minLength: 24)
            BottomBar()
        }
        .background(Color.homeBackground)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear {
            focused = true
            #if DEBUG
            // Screenshot hook, compiled out of release builds.
            switch ProcessInfo.processInfo.environment["CARTRIDGE_DEBUG_SHEET"] {
            case "setup": store.sheet = .setup
            case "help": store.sheet = .help
            case "game": if let g = store.games.first { store.sheet = .game(g.id) }
                if let files = ProcessInfo.processInfo.environment["CARTRIDGE_DEBUG_ADD"], let g = store.games.first {
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        store.addFiles(files.split(separator: ":").map { URL(fileURLWithPath: String($0)) }, to: g)
                    }
                }
            default: break
            }
            #endif
        }
        .onKeyPress(.leftArrow) { store.move(-1, 0); return .handled }
        .onKeyPress(.rightArrow) { store.move(1, 0); return .handled }
        .onKeyPress(.upArrow) { store.move(0, -1); return .handled }
        .onKeyPress(.downArrow) { store.move(0, 1); return .handled }
        .onKeyPress(.return) { store.quickPlay(); return .handled }
        .onKeyPress(.space) { store.activate(); return .handled }
        .onKeyPress(characters: ["a"]) { _ in store.quickPlay(); return .handled }
        .onKeyPress(characters: ["x"]) { _ in store.activate(); return .handled }
        .onKeyPress(characters: ["+", "="]) { _ in store.presentAddPanel(); return .handled }
        .dropDestination(for: URL.self) { urls, _ in store.add(folders: urls); return true }
        .sheet(item: $store.sheet) { sheet in
            switch sheet {
            case .game(let id): GameSheet(gameID: id)
            case .setup: SetupView()
            case .help: HelpView()
            case .update: UpdateView()
            case .whatsNew: WhatsNewView()
            case .launchFailed: LaunchFailedView()
            }
        }
        .onChange(of: store.sheet) { if store.sheet == nil { focused = true } }
        .onChange(of: store.updater.whatsNew) { if store.updater.whatsNew != nil, store.sheet == nil { store.sheet = .whatsNew } }
    }
}

// MARK: - Top bar

private struct TopBar: View {
    @State private var battery: Int?

    var body: some View {
        HStack(spacing: 12) {
            let name = Self.playerName
            ZStack {
                Circle().fill(LinearGradient(colors: [.focus, .blue], startPoint: .top, endPoint: .bottom))
                Text(name.prefix(1).uppercased()).font(.rounded(20, .bold)).foregroundStyle(.white)
            }
            .frame(width: 42, height: 42)
            .overlay(Circle().strokeBorder(.white.opacity(0.8), lineWidth: 2))
            .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
            Text(name).font(.rounded(15, .medium)).foregroundStyle(.secondary)
            Spacer()
            TimelineView(.everyMinute) { context in
                Text(context.date.formatted(date: .omitted, time: .shortened))
                    .font(.rounded(17, .medium)).monospacedDigit()
            }
            if let battery {
                HStack(spacing: 4) {
                    Text("\(battery)%").font(.rounded(13)).foregroundStyle(.secondary)
                    Image(systemName: battery > 75 ? "battery.100" : battery > 40 ? "battery.50" : "battery.25")
                        .font(.system(size: 17))
                }
            }
        }
        .padding(.horizontal, 36)
        .padding(.top, 22)
        .task {
            while !Task.isCancelled {
                battery = Self.batteryLevel()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    static var playerName: String {
        #if DEBUG
        if let name = ProcessInfo.processInfo.environment["CARTRIDGE_DEBUG_NAME"] { return name }
        #endif
        return NSFullUserName().split(separator: " ").first.map(String.init) ?? NSUserName()
    }

    static func batteryLevel() -> Int? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            if let desc = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
               let capacity = desc[kIOPSCurrentCapacityKey] as? Int { return capacity }
        }
        return nil
    }
}

private struct UpdateBanner: View {
    @Environment(Store.self) private var store

    var body: some View {
        Button { store.sheet = .update } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.focus)
                Text("Cartridge \(store.updater.latest?.version ?? "") is available").font(.rounded(14, .medium))
                Text("See What’s New").font(.rounded(14, .semibold)).foregroundStyle(Color.focus)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(Color.tileBackground, in: Capsule())
            .shadow(color: .black.opacity(0.08), radius: 4, y: 1)
        }
        .buttonStyle(.plain)
        .padding(.top, 10)
    }
}

private struct SetupBanner: View {
    @Environment(Store.self) private var store

    var body: some View {
        Button { store.sheet = .setup } label: {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                Text(store.missingCount == 1 ? "1 thing to set up before building" : "\(store.missingCount) things to set up before building")
                    .font(.rounded(14, .medium))
                Text("Set Up").font(.rounded(14, .semibold)).foregroundStyle(Color.focus)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(Color.tileBackground, in: Capsule())
            .shadow(color: .black.opacity(0.08), radius: 4, y: 1)
        }
        .buttonStyle(.plain)
        .padding(.top, 10)
    }
}

// MARK: - Game tiles

private struct GameRow: View {
    @Environment(Store.self) private var store
    static let tileSize: CGFloat = 236

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(Array(store.games.enumerated()), id: \.element.id) { index, game in
                        GameTile(game: game, selected: store.focusRow == 0 && store.selection == index)
                            .id(index)
                            .onTapGesture {
                                if store.selection == index && store.focusRow == 0 { store.activate() }
                                else { store.focusRow = 0; store.selection = index; store.click() }
                            }
                    }
                    AddTile(selected: store.focusRow == 0 && store.selection == store.games.count)
                        .id(store.games.count)
                        .onTapGesture { store.selection = store.games.count; store.presentAddPanel() }
                }
                .padding(.horizontal, 36)
                .padding(.top, 46) // room for the selected game's title
                .padding(.bottom, 14)
            }
            .onChange(of: store.selection) { withAnimation(.snappy) { proxy.scrollTo(store.selection, anchor: .center) } }
        }
        .frame(height: Self.tileSize + 60)
    }
}

private struct GameTile: View {
    @Environment(Store.self) private var store
    let game: LibraryGame
    let selected: Bool

    var body: some View {
        let folder = store.folders[game.id]
        // Before nxnative is downloaded there's no tested-games list, so don't call everything untested.
        let tested = store.catalog.entries.isEmpty || store.catalog[folder?.titleID] != nil
        let building = store.build?.gameID == game.id && store.build?.isRunning == true

        ZStack(alignment: .bottomLeading) {
            Group {
                if let image = store.artwork(for: game) {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    PlaceholderArt(title: store.title(for: game))
                }
            }
            .frame(width: GameRow.tileSize, height: GameRow.tileSize)
            .clipped()

            if building, let build = store.build {
                Color.black.opacity(0.55)
                ProgressRing(progress: build.progress)
                    .frame(width: 96, height: 96)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            HStack(spacing: 6) {
                let incompatible: Bool = {
                    if case .untested? = folder?.versionCheck(store.catalog[folder?.titleID]) { return true }
                    return false
                }()
                if incompatible {
                    Chip(text: "Not compatible", symbol: "xmark.circle.fill", tint: .red)
                } else if folder?.latestMacApp != nil {
                    Chip(text: "Ready", symbol: "play.fill", tint: .green)
                } else if folder?.latestIPA != nil {
                    Chip(text: "IPA", symbol: "iphone", tint: .blue)
                }
                if !tested { Chip(text: "Untested", symbol: "flask.fill", tint: .orange) }
            }
            .padding(10)
        }
        .frame(width: GameRow.tileSize, height: GameRow.tileSize)
        .background(Color.tileBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .shadow(color: .black.opacity(selected ? 0.25 : 0.12), radius: selected ? 10 : 4, y: selected ? 4 : 2)
        .overlay { if selected { FocusRing(cornerRadius: 6) } }
        .overlay(alignment: .topLeading) {
            if selected {
                Text(store.title(for: game))
                    .font(.rounded(19, .semibold))
                    .foregroundStyle(Color.focus)
                    .lineLimit(1)
                    .fixedSize()
                    .offset(y: -34)
            }
        }
        .scaleEffect(selected ? 1.0 : 0.97)
        .animation(.snappy(duration: 0.18), value: selected)
    }
}

private struct AddTile: View {
    let selected: Bool

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "plus").font(.system(size: 44, weight: .medium))
            Text("Add Game").font(.rounded(16, .semibold))
            Text("A folder with your\nNSP or XCI files").font(.rounded(12)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(selected ? Color.focus : .secondary)
        .frame(width: GameRow.tileSize, height: GameRow.tileSize)
        .background(Color.tileBackground.opacity(0.5))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6])).foregroundStyle(.secondary.opacity(0.5)))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay { if selected { FocusRing(cornerRadius: 6) } }
        .overlay(alignment: .topLeading) {
            if selected {
                Text("Add Game").font(.rounded(19, .semibold)).foregroundStyle(Color.focus).offset(y: -34)
            }
        }
        .scaleEffect(selected ? 1.0 : 0.97)
        .animation(.snappy(duration: 0.18), value: selected)
    }
}

/// Double ring (white inner, pulsing cyan outer) marking the focused item.
struct FocusRing: View {
    let cornerRadius: CGFloat
    @State private var pulse = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius + 5, style: .continuous)
                .strokeBorder(Color.focus.opacity(pulse ? 1 : 0.55), lineWidth: 4)
                .padding(-7)
            RoundedRectangle(cornerRadius: cornerRadius + 1, style: .continuous)
                .strokeBorder(.white, lineWidth: 3)
                .padding(-2)
        }
        .allowsHitTesting(false)
        .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever()) { pulse = true } }
    }
}

struct PlaceholderArt: View {
    let title: String

    var body: some View {
        let hue = Double(title.unicodeScalars.reduce(UInt32(7)) { ($0 &* 31) &+ $1.value } % 360) / 360
        ZStack {
            LinearGradient(colors: [Color(hue: hue, saturation: 0.55, brightness: 0.95),
                                    Color(hue: hue + 0.08, saturation: 0.75, brightness: 0.7)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 10) {
                Image(systemName: "gamecontroller.fill").font(.system(size: 40))
                Text(title).font(.rounded(18, .bold)).multilineTextAlignment(.center).lineLimit(3)
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
            .padding(18)
        }
    }
}

struct Chip: View {
    let text: String
    let symbol: String
    let tint: Color

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.rounded(11, .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(tint.gradient, in: Capsule())
            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
    }
}

struct ProgressRing: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.25), lineWidth: 8)
            Circle().trim(from: 0, to: progress)
                .stroke(Color.focus, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut, value: progress)
            Text("\(Int(progress * 100))%").font(.rounded(20, .bold)).foregroundStyle(.white).monospacedDigit()
        }
    }
}

// MARK: - Round buttons

private struct ButtonRow: View {
    @Environment(Store.self) private var store

    var body: some View {
        HStack(spacing: 22) {
            ForEach(HomeButton.allCases) { button in
                let selected = store.focusRow == 1 && store.buttonSelection == button.rawValue
                VStack(spacing: 8) {
                    ZStack {
                        Circle().fill(Color.tileBackground)
                            .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                        Image(systemName: button.symbol)
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(button.tint)
                            .symbolEffect(.pulse, isActive: button == .update && store.isUpdatingRepo)
                        if (button == .setup && store.missingCount > 0) || (button == .update && store.nxnativeUpdateAvailable) {
                            Circle().fill(.red).frame(width: 12, height: 12)
                                .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                                .offset(x: 20, y: -20)
                        }
                    }
                    .frame(width: 60, height: 60)
                    .overlay {
                        if selected {
                            Circle().strokeBorder(.white, lineWidth: 3).padding(-2)
                            Circle().strokeBorder(Color.focus, lineWidth: 4).padding(-7)
                        }
                    }
                    Text(button.title)
                        .font(.rounded(12, .medium))
                        .foregroundStyle(selected ? Color.focus : .secondary)
                        .opacity(selected ? 1 : 0.85)
                }
                .frame(width: 76)
                .contentShape(Rectangle())
                .onTapGesture {
                    store.focusRow = 1
                    store.buttonSelection = button.rawValue
                    store.play("Pop")
                    button.perform(store)
                }
                .help(button.title)
            }
        }
    }
}

// MARK: - Bottom bar

private struct BottomBar: View {
    @Environment(Store.self) private var store
    @Environment(ControllerMonitor.self) private var controller

    var body: some View {
        VStack(spacing: 0) {
            Divider().padding(.horizontal, 24)
            HStack(spacing: 18) {
                Label(controller.name ?? "Keyboard", systemImage: controller.name == nil ? "keyboard" : "gamecontroller.fill")
                    .font(.rounded(13, .medium))
                    .foregroundStyle(.secondary)
                if let build = store.build, build.isRunning {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Building \(build.title) · \(Int(build.progress * 100))%").font(.rounded(13, .medium))
                    }
                    .onTapGesture { store.sheet = .game(build.gameID) }
                } else if store.nxnativeUpdateAvailable {
                    Text("nxnative update available").font(.rounded(12, .medium)).foregroundStyle(.blue)
                } else if !store.repoStatus.isEmpty {
                    Text("nxnative · \(store.repoStatus)").font(.rounded(12)).foregroundStyle(.tertiary)
                }
                Spacer()
                let hasApp = store.selectedGame.flatMap { store.folders[$0.id]?.latestMacApp } != nil
                Hint(key: "A", text: store.focusRow == 1 ? "Select" : (hasApp ? "Play" : "Open"))
                Hint(key: "X", text: "Details")
                Hint(key: "+", text: "Add Game")
            }
            .padding(.horizontal, 36)
            .frame(height: 52)
        }
    }
}

private struct Hint: View {
    let key: String
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Text(key)
                .font(.rounded(11, .heavy))
                .foregroundStyle(Color.homeBackground)
                .frame(width: 20, height: 20)
                .background(Circle().fill(.primary))
            Text(text).font(.rounded(13, .medium))
        }
    }
}
