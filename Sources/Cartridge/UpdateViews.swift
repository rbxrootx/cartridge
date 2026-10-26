import CartridgeCore
import SwiftUI

/// Changelogs for every version newer than this one, with install options.
struct UpdateView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let updater = store.updater
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 60, height: 60)
                VStack(alignment: .leading, spacing: 3) {
                    Text(updater.latest.map { "Cartridge \($0.version) is available" } ?? "Cartridge is up to date")
                        .font(.rounded(22, .bold))
                    Text("You have version \(updater.currentVersion).").foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(22)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(updater.updates) { ReleaseNotesView(release: $0) }
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                switch updater.state {
                case .downloading: ProgressView().controlSize(.small); Text("Downloading…").foregroundStyle(.secondary)
                case .installing: ProgressView().controlSize(.small); Text("Installing…").foregroundStyle(.secondary)
                case .failed(let message): Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).lineLimit(2)
                default:
                    if store.build?.isRunning == true {
                        Text("Updating is available once the current build finishes.").foregroundStyle(.secondary)
                    } else {
                        Button("Skip This Version") { updater.skipLatest(); dismiss() }
                    }
                }
                Spacer()
                Button("Later") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Install and Relaunch") { updater.installLatest() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(updater.latest == nil || store.build?.isRunning == true
                              || updater.state == .downloading || updater.state == .installing)
            }
            .padding(16)
        }
        .frame(width: 560, height: 560)
    }
}

/// Shown once, the first time a new version launches.
struct WhatsNewView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 60, height: 60)
                VStack(alignment: .leading, spacing: 3) {
                    Text("What’s New in Cartridge \(store.updater.currentVersion)").font(.rounded(22, .bold))
                    Text("You’re up to date.").foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(22)
            Divider()
            ScrollView {
                if let release = store.updater.whatsNew {
                    ReleaseNotesView(release: release, showTitle: false).padding(22)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Divider()
            HStack {
                Spacer()
                Button("Continue") { store.updater.dismissWhatsNew(); dismiss() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 520, height: 480)
        .onDisappear { store.updater.dismissWhatsNew() }
    }
}

struct ReleaseNotesView: View {
    let release: Release
    var showTitle = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showTitle {
                HStack(alignment: .firstTextBaseline) {
                    Text(release.title).font(.rounded(18, .bold))
                    if let date = release.publishedAt {
                        Text(date, style: .date).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Link("View on GitHub", destination: release.htmlURL).font(.callout)
                }
            }
            let blocks = ReleaseNotes.parse(release.body ?? "")
            if blocks.isEmpty {
                Text("No release notes.").foregroundStyle(.secondary)
            }
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let text):
                    Text(text).font(.headline).padding(.top, 6)
                case .bullet(let text):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(Color.focus)
                        Text(Self.inline(text)).fixedSize(horizontal: false, vertical: true)
                    }
                case .paragraph(let text):
                    Text(Self.inline(text)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .textSelection(.enabled)
    }

    /// Inline Markdown (bold, code, links) in a note line.
    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }
}
