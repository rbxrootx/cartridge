import SwiftUI

@main
struct CartridgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = Store.shared
    @State private var controller = ControllerMonitor(store: Store.shared)

    var body: some Scene {
        Window("Cartridge", id: "home") {
            HomeView()
                .environment(store)
                .environment(controller)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 720)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    Task {
                        await store.updater.check(userInitiated: true)
                        store.sheet = .update
                    }
                }
            }
            CommandGroup(replacing: .newItem) {
                Button("Add Game…") { store.presentAddPanel() }.keyboardShortcut("o")
            }
            CommandMenu("Game") {
                Button("Play or Open") { store.quickPlay() }.keyboardShortcut(.return, modifiers: [])
                Button("Details…") { store.activate() }.keyboardShortcut("i")
                Divider()
                Button("Setup…") { store.sheet = .setup }.keyboardShortcut(",", modifiers: [.command, .shift])
                Button("Update nxnative") { store.updateRepo() }
                Button("Reload Library") { store.refresh() }.keyboardShortcut("r")
            }
            CommandGroup(replacing: .help) {
                Button("Cartridge Help") { store.sheet = .help }
            }
        }

        Settings {
            SettingsView().environment(store)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if ProcessInfo.processInfo.environment["CARTRIDGE_DEBUG_APPEARANCE"] == "dark" {
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
        #endif
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let running = MainActor.assumeIsolated { Store.shared.build?.isRunning == true }
        guard running else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "A game is still building"
        alert.informativeText = "Quitting stops the build. Finished steps are kept, so the next build continues from there."
        alert.addButton(withTitle: "Keep Building")
        alert.addButton(withTitle: "Stop and Quit")
        if alert.runModal() == .alertFirstButtonReturn { return .terminateCancel }
        MainActor.assumeIsolated { Store.shared.cancelBuild() }
        return .terminateNow
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { Store.shared.add(folders: urls) }
    }
}
