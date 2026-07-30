import Testing
import Foundation
@testable import ArchiveNotes

/// W23.m3 (Tier-2) — the inline-image **read** seam, on scratch fixtures (temp dirs; never the real
/// Notes store or the archival corpus). Each escape test first proves the bytes ARE reachable by the
/// old "append the reference, check it exists" rule, so the test documents the hole it closes rather
/// than just asserting the new verdict.
@Suite("AssetPathResolver — inline-image read-seam containment (W23.m3)")
struct AssetPathResolverTests {

    /// `<tmp>/items/{A,B}/assets/…` — the store shape `NoteStore.itemDir` produces, with a second item
    /// to escape *to*, plus a sibling directory whose name starts with "assets".
    private struct Fixture {
        let root: URL
        let itemA: URL
        let itemB: URL

        init() throws {
            let fm = FileManager.default
            root = fm.temporaryDirectory
                .appendingPathComponent("AssetPathResolverTests-\(UUID().uuidString)", isDirectory: true)
            itemA = root.appendingPathComponent("items/A", isDirectory: true)
            itemB = root.appendingPathComponent("items/B", isDirectory: true)
            try fm.createDirectory(at: itemA.appendingPathComponent("assets"), withIntermediateDirectories: true)
            try fm.createDirectory(at: itemB.appendingPathComponent("assets"), withIntermediateDirectories: true)
            try fm.createDirectory(at: itemA.appendingPathComponent("assets-elsewhere"),
                                   withIntermediateDirectories: true)
            try Data("A-OWN-BYTES".utf8).write(to: itemA.appendingPathComponent("assets/own.png"))
            try Data("B-PRIVATE-BYTES".utf8).write(to: itemB.appendingPathComponent("assets/private.png"))
            try Data("A-SIBLING-BYTES".utf8).write(to: itemA.appendingPathComponent("assets-elsewhere/x.png"))
            try Data("A-LOOSE-BYTES".utf8).write(to: itemA.appendingPathComponent("loose.png"))
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }

        /// The pre-fix rule, verbatim: append the reference to the item dir and accept it if it exists.
        func reachableByOldRule(_ reference: String) -> Bool {
            FileManager.default.fileExists(
                atPath: itemA.appendingPathComponent(reference).path)
        }

        func resolveInA(_ reference: String) -> AssetResolution {
            AssetPathResolver.resolve(reference, inItemDirectory: itemA)
        }
    }

    // MARK: - In bounds: the everyday case still works

    @Test("An item's own assets/<name> resolves to a canonical URL holding its own bytes")
    func ownAssetResolves() throws {
        let fx = try Fixture()
        defer { fx.cleanup() }

        guard case .resolved(let url) = fx.resolveInA("assets/own.png") else {
            Issue.record("expected .resolved for the item's own asset")
            return
        }
        #expect(try Data(contentsOf: url) == Data("A-OWN-BYTES".utf8))
        // Canonical: symlink-resolved and standardized, so it is a stable identity for the asset.
        #expect(url == url.resolvingSymlinksInPath().standardizedFileURL)
        #expect(url.lastPathComponent == "own.png")
    }

    @Test("A nested reference inside assets/ resolves (containment, not a flat-folder rule)")
    func nestedAssetResolves() throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        let sub = fx.itemA.appendingPathComponent("assets/sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data("NESTED".utf8).write(to: sub.appendingPathComponent("deep.png"))

        guard case .resolved(let url) = fx.resolveInA("assets/sub/deep.png") else {
            Issue.record("expected .resolved for a nested in-bounds asset")
            return
        }
        #expect(try Data(contentsOf: url) == Data("NESTED".utf8))
    }

    @Test("A symlink inside assets/ pointing at another asset in the SAME item still resolves")
    func inBoundsSymlinkResolves() throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        try FileManager.default.createSymbolicLink(
            at: fx.itemA.appendingPathComponent("assets/alias.png"),
            withDestinationURL: fx.itemA.appendingPathComponent("assets/own.png"))

        guard case .resolved(let url) = fx.resolveInA("assets/alias.png") else {
            Issue.record("expected .resolved — the symlink target is inside the same assets dir")
            return
        }
        #expect(try Data(contentsOf: url) == Data("A-OWN-BYTES".utf8))
    }

    // MARK: - Missing: in bounds, nothing there

    @Test("A dangling in-bounds reference is .missing, not .outOfBounds")
    func danglingReferenceIsMissing() throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        #expect(fx.resolveInA("assets/nope.png") == .missing)
        #expect(fx.resolveInA("assets/sub/nope.png") == .missing)
    }

    // MARK: - Out of bounds: the W23.m3 escapes

    @Test("`../OTHER/assets/private.png` is refused — the reported escape")
    func parentTraversalRefused() throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        let escape = "../B/assets/private.png"

        // The defect: the old rule finds another item's bytes.
        #expect(fx.reachableByOldRule(escape))
        #expect(fx.resolveInA(escape) == .outOfBounds)
    }

    @Test("A traversal that starts inside assets/ is refused")
    func traversalFromInsideAssetsRefused() throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        let escape = "assets/../../B/assets/private.png"

        #expect(fx.reachableByOldRule(escape))
        #expect(fx.resolveInA(escape) == .outOfBounds)
    }

    @Test("A symlink inside assets/ pointing OUT of the item is refused (fileExists follows it)")
    func escapingSymlinkRefused() throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        try FileManager.default.createSymbolicLink(
            at: fx.itemA.appendingPathComponent("assets/leak.png"),
            withDestinationURL: fx.itemB.appendingPathComponent("assets/private.png"))

        // Syntactically this is an ordinary `assets/<name>` reference and the file "exists" …
        #expect(fx.reachableByOldRule("assets/leak.png"))
        // … but its canonical target is another item, so the read seam refuses it.
        #expect(fx.resolveInA("assets/leak.png") == .outOfBounds)
    }

    @Test("A symlink into a sibling dir whose name starts with `assets` is refused")
    func siblingPrefixDirectoryRefused() throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        try FileManager.default.createSymbolicLink(
            at: fx.itemA.appendingPathComponent("assets/sibling.png"),
            withDestinationURL: fx.itemA.appendingPathComponent("assets-elsewhere/x.png"))

        #expect(fx.reachableByOldRule("assets/sibling.png"))
        #expect(fx.resolveInA("assets/sibling.png") == .outOfBounds)
    }

    @Test("A reference outside assets/ is refused even inside the item's own directory")
    func nonAssetsReferenceRefused() throws {
        let fx = try Fixture()
        defer { fx.cleanup() }

        #expect(fx.reachableByOldRule("loose.png"))
        #expect(fx.resolveInA("loose.png") == .outOfBounds)
        #expect(fx.resolveInA("assets-elsewhere/x.png") == .outOfBounds)
        // `assets` itself names no file.
        #expect(fx.resolveInA("assets") == .outOfBounds)
        #expect(fx.resolveInA("") == .outOfBounds)
    }

    @Test("Absolute, home-relative and remote references are refused")
    func absoluteAndRemoteRefused() throws {
        let fx = try Fixture()
        defer { fx.cleanup() }

        #expect(fx.resolveInA(fx.itemB.appendingPathComponent("assets/private.png").path) == .outOfBounds)
        #expect(fx.resolveInA("/etc/hosts") == .outOfBounds)
        #expect(fx.resolveInA("~/.ssh/id_rsa") == .outOfBounds)
        #expect(fx.resolveInA("https://example.com/x.png") == .outOfBounds)
    }

    @Test("An item directory reached through a symlink still resolves its own asset")
    func symlinkedItemDirResolves() throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        // The store root itself can sit behind a symlink (on macOS every temp dir does, via
        // /var → /private/var). Both sides of the containment comparison are canonicalized the same
        // way, so an aliased spelling of the item directory must not read as a *different* directory.
        let aliasedItemA = fx.root.appendingPathComponent("alias-A")
        try FileManager.default.createSymbolicLink(at: aliasedItemA, withDestinationURL: fx.itemA)

        guard case .resolved(let url) = AssetPathResolver.resolve("assets/own.png",
                                                                  inItemDirectory: aliasedItemA) else {
            Issue.record("expected .resolved for a symlink-aliased item directory")
            return
        }
        #expect(try Data(contentsOf: url) == Data("A-OWN-BYTES".utf8))
    }
}
