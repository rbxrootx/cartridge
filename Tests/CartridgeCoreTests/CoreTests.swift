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
}
