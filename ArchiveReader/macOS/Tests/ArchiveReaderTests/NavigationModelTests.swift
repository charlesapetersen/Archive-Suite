import XCTest
@testable import ArchiveReader

/// R-4: `NavigationModel.sanitizedPathPrefix` guards a restored/saved filter whose folder scope may
/// predate a root change. It must drop a prefix outside the current root but keep a valid subtree, so
/// `applySaved`/`restoreViewState` never restore a scope that makes recompute reject every file.
final class NavigationModelTests: XCTestCase {

    func testSanitizedPathPrefixKeepsValidSubtree() {
        let root = "/Users/x/Archive"
        // The root itself and any subtree under it are valid.
        XCTAssertEqual(NavigationModel.sanitizedPathPrefix(root, against: root), root)
        XCTAssertEqual(NavigationModel.sanitizedPathPrefix("/Users/x/Archive/Box1", against: root),
                       "/Users/x/Archive/Box1")
        XCTAssertEqual(NavigationModel.sanitizedPathPrefix("/Users/x/Archive/Box1/Folder2", against: root),
                       "/Users/x/Archive/Box1/Folder2")
        // A trailing slash on the root is tolerated.
        XCTAssertEqual(NavigationModel.sanitizedPathPrefix("/Users/x/Archive/Box1", against: root + "/"),
                       "/Users/x/Archive/Box1")
    }

    func testSanitizedPathPrefixDropsOutOfRootPrefix() {
        let root = "/Users/x/Archive"
        // A scope under a different root is dropped.
        XCTAssertNil(NavigationModel.sanitizedPathPrefix("/Users/x/OtherRoot/Box1", against: root))
        // A sibling whose path merely shares a NAME prefix (ArchiveBox vs Archive) must NOT survive —
        // the component-boundary test is why we don't use a plain hasPrefix.
        XCTAssertNil(NavigationModel.sanitizedPathPrefix("/Users/x/ArchiveBox", against: root))
        XCTAssertNil(NavigationModel.sanitizedPathPrefix("/Users/x/ArchiveBox/Sub", against: root))
    }

    func testSanitizedPathPrefixPassesThroughWhenNothingToValidate() {
        // No prefix → nil; no root → prefix unchanged (nothing to validate against).
        XCTAssertNil(NavigationModel.sanitizedPathPrefix(nil, against: "/Users/x/Archive"))
        XCTAssertEqual(NavigationModel.sanitizedPathPrefix("/anything", against: nil), "/anything")
    }
}
