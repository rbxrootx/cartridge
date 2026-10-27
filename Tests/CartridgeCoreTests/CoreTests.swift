@testable import CartridgeCore
import XCTest

final class CoreTests: XCTestCase {
    func testFileNames() {
        let base = GameFile.parse(URL(fileURLWithPath: "/g/Starlight Garden [0500000000010000][v0].nsp"))
        XCTAssertEqual(base.titleID, "0500000000010000")
        XCTAssertEqual(base.kind, .base)
        XCTAssertEqual(base.version, 0)
        XCTAssertEqual(base.displayName, "Starlight Garden")

        let update = GameFile.parse(URL(fileURLWithPath: "/g/Starlight Garden [0500000000010800][v327680].nsp"))
        XCTAssertEqual(update.kind, .update)
        XCTAssertEqual(update.baseTitleID, "0500000000010000")
        XCTAssertEqual(GameFolder.versionLabel(update.version!), "Update 5 (v327680)")

        let dlc = GameFile.parse(URL(fileURLWithPath: "/g/Starlight Garden Extra [0500000000011001][v0].nsp"))
        XCTAssertEqual(dlc.kind, .dlc)
        XCTAssertEqual(dlc.baseTitleID, "0500000000010000")

        let odd = GameFile.parse(URL(fileURLWithPath: "/g/mygame.xci"))
        XCTAssertNil(odd.titleID)
        XCTAssertEqual(odd.kind, .unknown)
    }

    func testCatalog() {
        let index = """
        | Game | Title ID | Build | SDK | Engine | Graphics |
        |---|---|---|---|---|---|
        | [Pixel Rally](0500000000020000/README.md) | `0500000000020000` | 1.10 | 11.4.3 | x | NVN |
        | [Pixel Rally, Deluxe Edition](0500000000030000/README.md) | `0500000000030000` | 1.00 | 11.4.3 | x | NVN |
        """
        let readme = #"<img src="docs/images/pixel-rally.jpg" width="256" alt="Pixel Rally"><br>"#
        let entries = Catalog.parse(gamesIndex: index, readme: readme, repo: URL(fileURLWithPath: "/r"))
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries["0500000000020000"]?.artwork?.path, "/r/docs/images/pixel-rally.jpg")
        XCTAssertEqual(entries["0500000000030000"]?.artwork?.path, "/r/docs/images/pixel-rally.jpg") // prefix match
    }

    func testEvents() {
        XCTAssertEqual(BuildEvent.parse(#"{"ev": "stage", "k": 2, "n": 9, "name": "extract", "step": "", "t": 1.0}"#),
                       .stage(k: 2, n: 9, name: "extract", step: ""))
        XCTAssertEqual(BuildEvent.parse(#"{"ev": "progress", "k": 2, "name": "extract", "step": "romfs", "done": 5, "total": 10, "frac": 0.5, "eta": 12.5, "elapsed": 3}"#),
                       .progress(k: 2, name: "extract", step: "romfs", fraction: 0.5, eta: 12.5, note: nil))
        XCTAssertEqual(BuildEvent.parse(#"{"ev": "say", "msg": "[RED] dotnet not found (.NET SDK 10)"}"#),
                       .message("dotnet not found (.NET SDK 10)", .error))
        XCTAssertEqual(BuildEvent.parse("plain text"), .unparsed("plain text"))
        // Real output from nxnative's JSON mode.
        XCTAssertEqual(BuildEvent.parse(#"{"ev": "say", "msg": "[15:51:08] skipping an empty file: X [0500000000010000][v0].nsp", "t": 1.0}"#),
                       .message("skipping an empty file: X [0500000000010000][v0].nsp", .info))
    }

    func testKeysShape() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let good = dir.appendingPathComponent("prod.keys"), bad = dir.appendingPathComponent("notes.txt")
        // Dummy values: only the file's shape is checked.
        try (0..<6).map { "test_key_\($0) = \(String(repeating: "0", count: 32))" }.joined(separator: "\n")
            .write(to: good, atomically: true, encoding: .utf8)
        try "hello".write(to: bad, atomically: true, encoding: .utf8)
        XCTAssertEqual(KeysFile.validate(good), .valid)
        XCTAssertEqual(KeysFile.validate(bad), .invalid)
        XCTAssertEqual(KeysFile.validate(dir.appendingPathComponent("nope")), .missing)
    }

    /// The real nxnative docs, if a checkout is available (CARTRIDGE_TEST_REPO).
    func testRealCatalog() throws {
        guard let path = ProcessInfo.processInfo.environment["CARTRIDGE_TEST_REPO"] else { throw XCTSkip("no repo") }
        let catalog = Catalog(repo: URL(fileURLWithPath: path))
        XCTAssertGreaterThan(catalog.entries.count, 60)
        let withArt = catalog.entries.values.filter { $0.artwork.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }
        print("catalog: \(catalog.entries.count) games, \(withArt.count) with artwork")
        XCTAssertGreaterThan(withArt.count, 55)
    }

    func testXcodeDetection() {
        let all = XcodeInstall.all()
        print("xcodes:", all.map { "\($0.version) metal4=\($0.hasMetal4)" })
        XCTAssertFalse(all.isEmpty)
        if let m4 = XcodeInstall.metal4 { XCTAssertTrue(m4.hasMetal4) }
    }

    func testVersions() {
        XCTAssertTrue(Version.isNewer("v1.10.0", than: "1.9.3"))
        XCTAssertFalse(Version.isNewer("1.0", than: "1.0.0"))
        XCTAssertFalse(Version.isNewer("v1.0.1", than: "1.0.1"))
        XCTAssertTrue(Version.isNewer("2", than: "1.99"))
    }

    func testReleaseDecodingAndFiltering() throws {
        let json = #"""
        [{"tag_name": "v1.2.0", "name": "", "body": "### Added\n- Updates\n  wrapped", "html_url": "https://example.com/1",
          "published_at": "2026-10-27T10:00:00Z", "draft": false, "prerelease": false,
          "assets": [{"name": "Cartridge.zip", "browser_download_url": "https://example.com/z", "size": 10}]},
         {"tag_name": "v1.1.0", "name": "Cartridge 1.1.0", "body": null, "html_url": "https://example.com/2",
          "published_at": null, "draft": false, "prerelease": false, "assets": []},
         {"tag_name": "v1.3.0-beta", "name": "b", "body": "", "html_url": "https://example.com/3",
          "published_at": null, "draft": false, "prerelease": true, "assets": []},
         {"tag_name": "v1.0.0", "name": "", "body": "", "html_url": "https://example.com/4",
          "published_at": null, "draft": false, "prerelease": false, "assets": []}]
        """#
        let releases = try Release.decodeList(Data(json.utf8))
        let updates = Version.updates(from: releases, current: "1.0.1")
        XCTAssertEqual(updates.map(\.version), ["1.2.0", "1.1.0"])
        XCTAssertEqual(updates[0].title, "Cartridge 1.2.0")
        XCTAssertNotNil(updates[0].asset(named: "Cartridge.zip"))
        XCTAssertEqual(ReleaseNotes.parse(updates[0].body!), [.heading("Added"), .bullet("Updates wrapped")])
    }

    func testTestedVersions() {
        let tsv = "# comment\nbuild\tv1114112\t1.9.0\tmain=ab\nshader_versions\tv1114112\n"
        XCTAssertEqual(Catalog.testedVersions(gameTSV: tsv), [Catalog.TestedVersion(code: 1114112, display: "1.9.0")])
        var entry = Catalog.Entry(titleID: "0500000000010000", name: "Starlight Garden")
        entry.testedVersions = Catalog.testedVersions(gameTSV: tsv)
        let baseOnly = GameFolder(url: URL(fileURLWithPath: "/g"),
                                  files: [GameFile.parse(URL(fileURLWithPath: "/g/X [0500000000010000][v0].nsp"))], outputs: [])
        XCTAssertEqual(baseOnly.versionCheck(entry), .untested(have: [0], tested: entry.testedVersions))
        var withUpdate = baseOnly
        withUpdate.files.append(GameFile.parse(URL(fileURLWithPath: "/g/X [0500000000010800][v1114112].nsp")))
        XCTAssertEqual(withUpdate.versionCheck(entry), .tested(1114112))
        XCTAssertEqual(baseOnly.versionCheck(nil), .unknown)
    }
}
