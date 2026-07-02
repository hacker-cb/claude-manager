import Foundation
import Testing
@testable import ClaudeManagerCore

struct MetadataStoreTests {
    let fm = FileManager.default

    @Test
    func savesAndLoadsRoundTrip() throws {
        let dir = try Fixture.makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        let store = MetadataStore(directory: dir)
        try store.save(["id.a": LauncherMetadata(order: 1, notes: "hi")])
        #expect(store.load()["id.a"] == LauncherMetadata(order: 1, notes: "hi"))
    }

    @Test
    func missingFileLoadsEmpty() throws {
        let dir = try Fixture.makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        #expect(MetadataStore(directory: dir).load().isEmpty)
    }

    @Test
    func updateMutatesSingleEntry() throws {
        let dir = try Fixture.makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        let store = MetadataStore(directory: dir)
        try store.update(bundleID: "id.a") { $0.order = 5 }
        try store.update(bundleID: "id.a") { $0.notes = "n" }
        try store.update(bundleID: "id.b") { $0.order = 9 }
        let loaded = store.load()
        #expect(loaded["id.a"] == LauncherMetadata(order: 5, notes: "n"))
        #expect(loaded["id.b"] == LauncherMetadata(order: 9, notes: nil))
    }

    @Test
    func defaultDirectoryIsUnderApplicationSupport() {
        let dir = MetadataStore.defaultDirectory()
        #expect(dir.path.contains("Application Support/Claude Manager"))
    }
}
