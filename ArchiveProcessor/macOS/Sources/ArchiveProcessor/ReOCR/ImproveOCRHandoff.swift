import AppKit
import ArchiveCore
import Foundation

// MARK: - Improve OCR: an incoming hand-off from the Reader (W44.reocr-processor)

/// Turns an `archiveprocessor://improve-ocr` link into the files the dialog opens for (`execution-plans/reocr/00-plan
/// .md` §3). A hand-off only opens the review dialog: it never runs a reading, spends money, clears a flag or writes a
/// file. The request is checked and recorded by `ImproveOCRRequestStore` (so a replayed link opens nothing twice); the
/// archive is found through the Processor's own saved grant for that root, or the Processor's own folder panel, and
/// must carry the root marker the request names. A path in the request is only ever resolved inside that root.
@MainActor
enum ImproveOCRHandoff {
    enum Outcome: Equatable {
        /// The files, and for a file the Reader named pairs for, those pairs (0-based image/text pairs).
        case open([URL], pairs: [URL: [Int]] = [:])
        /// Shown to the person instead of the dialog.
        case message(String)
    }

    static let grantsKey = "ImproveOCR.rootGrants"

    /// A link that arrived before the Process Files view could take it (a cold launch, another tab): that view takes it
    /// when it appears.
    static var pending: URL?

    static func handle(_ url: URL, connection: ReOCRSupportConnection, defaults: UserDefaults = .standard,
                       chooseRoot: @MainActor (UUID) -> URL? = askForRoot) -> Outcome {
        let request: ImproveOCRRequest
        do { request = try ImproveOCRRequest(url: url) } catch { return .message("This Improve OCR link cannot be read (\(error)).") }
        let support: ReOCRSupportConnection.Connected
        do { support = try connection.resolve() } catch { return .message("\(error)") }
        let store = ImproveOCRRequestStore(sharedSupport: support.url,
                                           privateState: ImproveOCRController.privateFolder.appendingPathComponent("Requests", isDirectory: true))
        switch store.receive(request, consumes: false) {
        case .alreadyOpened: return .message("This Improve OCR request was opened already.")
        case .selectAgain(_, let why): return .message("Select the files again in the Reader: \(why).")
        case .refused(let why): return .message("This Improve OCR request was refused: \(why).")
        case .open(let resolved):
            guard let root = root(resolved.rootGUID, hint: resolved.rootPathHint, defaults: defaults, choose: chooseRoot) else {
                return .message("The archive this request names is not available to the Processor.")
            }
            var files: [URL] = []
            var pairs: [URL: [Int]] = [:]
            for entry in resolved.entries {
                let file = root.appendingPathComponent(entry.relativePath)
                // Inside the root after links are resolved, a regular file, and the file the Reader saw.
                var st = stat()
                guard (try? ImproveOCRFlagStore.FileKey(rootGUID: resolved.rootGUID, root: root, file: file)) != nil,
                      stat(file.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
                    return .message("\(entry.relativePath) is not a file inside the archive.")
                }
                if let n = entry.expectedFileNumber, UInt64(st.st_ino) != n {
                    return .message("\(entry.relativePath) was replaced since it was selected; select it again in the Reader.")
                }
                if let size = entry.expectedByteCount, Int64(st.st_size) != size {
                    return .message("\(entry.relativePath) changed since it was selected; select it again in the Reader.")
                }
                if let sha = entry.expectedSHA256, (try? ReOCRFileWriter.snapshot(file.path))?.sha256 != sha.lowercased() {
                    return .message("\(entry.relativePath) changed since it was selected; select it again in the Reader.")
                }
                files.append(file)
                if let chosen = entry.pairIndices { pairs[file] = chosen }
            }
            guard !files.isEmpty else { return .message("The request names no files.") }
            // Only now, with everything in hand, is the request recorded as opened.
            if let used = store.markOpened(resolved.requestID) {
                if case .alreadyOpened = used { return .message("This Improve OCR request was opened already.") }
                return .message("This Improve OCR request cannot be recorded: \(used).")
            }
            return .open(files, pairs: pairs)
        }
    }

    /// The archive root with `guid`: the saved grant, else the hint, else the person's choice; each checked against the
    /// root marker, and a checked choice saved as the grant.
    static func root(_ guid: UUID, hint: String?, defaults: UserDefaults, choose: @MainActor (UUID) -> URL?) -> URL? {
        func matches(_ url: URL) -> Bool { (try? RootMarker.read(at: url))?.guid == guid }
        var grants = defaults.dictionary(forKey: grantsKey) as? [String: Data] ?? [:]
        // The Reader's hint first (where the archive is now), then the saved grant, then the person's choice.
        let hinted = hint.map { URL(fileURLWithPath: $0, isDirectory: true) }.flatMap { matches($0) ? $0 : nil }
        var granted: URL?
        if hinted == nil, let data = grants[guid.uuidString] {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale),
               matches(url) {
                if !stale { return url }
                granted = url
            }
        }
        guard let url = hinted ?? granted ?? choose(guid).flatMap({ matches($0) ? $0 : nil }) else { return nil }
        if let data = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            grants[guid.uuidString] = data
            defaults.set(grants, forKey: grantsKey)
        }
        return url
    }

    static func askForRoot(_ guid: UUID) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Use This Archive"
        panel.message = "Choose the archive folder the Archive Reader sent these files from."
        return panel.runModal() == .OK ? panel.url : nil
    }
}
