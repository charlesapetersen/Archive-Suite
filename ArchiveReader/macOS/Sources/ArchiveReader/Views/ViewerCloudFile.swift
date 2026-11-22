import Foundation
import os
import SwiftUI

enum ViewerCloudFile {
    static func isDataless(_ path: String, flags: UInt32) -> Bool {
        #if DEBUG
        if let fixture, path == fixture.path, !fixture.downloaded.withLock({ $0 }) { return true }
        #endif
        return flags & UInt32(SF_DATALESS) != 0
    }

    /// The File Provider fetches the file when its data is read. As in Notes, allow that only on the
    /// thread doing the user's download, then restore its policy before the thread returns to the pool.
    static func download(_ url: URL) -> Bool {
        let prior = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        guard setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD,
                             IOPOL_MATERIALIZE_DATALESS_FILES_ON) == 0 else { return false }
        defer {
            _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD,
                               prior >= 0 ? prior : IOPOL_DEFAULT)
        }
        let fd = url.withUnsafeFileSystemRepresentation { $0.map { Darwin.open($0, O_RDONLY) } ?? -1 }
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var byte: UInt8 = 0
        guard read(fd, &byte, 1) == 1 else { return false }
        var info = stat()
        guard stat(url.path, &info) == 0, info.st_flags & UInt32(SF_DATALESS) == 0 else { return false }

        #if DEBUG
        if let fixture, url.path == fixture.path { fixture.downloaded.withLock { $0 = true } }
        #endif
        return true
    }

    #if DEBUG
    /// The offline GUI VM has no cloud account. Simulate the status of one file in its scratch archive.
    /// The normal download action still opens and reads it before the simulated flag can clear.
    private struct Fixture: Sendable {
        let path: String
        let downloaded = OSAllocatedUnfairLock(initialState: false)
    }

    private static let fixture: Fixture? = {
        let args = ProcessInfo.processInfo.arguments
        guard let root = args.firstIndex(of: "-ARUITestRootPath"), root + 1 < args.count,
              let index = args.firstIndex(of: "-ARUITestCloudFile"), index + 1 < args.count else { return nil }
        let path = args[index + 1]
        guard path.hasPrefix(args[root + 1] + "/") else { return nil }
        return Fixture(path: path)
    }()
    #endif
}

struct CloudDocumentPlaceholder: View {
    let title: String
    let state: DocumentViewerModel.CloudState
    let idPrefix: String
    let download: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "icloud")
                .accessibilityIdentifier("\(idPrefix).cloudFile")
        } description: {
            Text(state == .downloadFailed
                 ? "The file couldn’t be downloaded. Check your connection and try again."
                 : "Showing it downloads the whole file to this Mac.")
        } actions: {
            if state == .downloading {
                ProgressView("Downloading…").controlSize(.small)
            } else {
                Button("Download and Show", action: download)
                    .accessibilityIdentifier("\(idPrefix).downloadCloudFile")
            }
        }
    }
}
