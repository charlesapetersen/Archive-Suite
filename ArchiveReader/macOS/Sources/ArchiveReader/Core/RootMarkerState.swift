// RootMarkerState.swift — whether the granted archive root has an identity links can be minted from.
// Part of Archive Reader (W23.m6).

import Foundation
import ArchiveCore

/// Why a granted root has no identity to mint durable links from.
///
/// Each case is a different thing the reader can actually do something about, which is the point:
/// the marker layer used to paper over all of them — a read-only volume handed back an in-memory
/// GUID that changed at the next launch, and an unreadable marker looked exactly like no marker at
/// all — so the app either minted links that could never resolve, or went quiet with no reason.
enum RootMarkerDegradation: Equatable {
    /// The folder could not be written, so the identity would live only in memory
    /// (read-only volume, no write permission, disk full).
    case notWritable
    /// A marker file is there but does not decode. It is never overwritten: minting a replacement
    /// GUID would orphan every link already copied from this root.
    case malformed
    /// A marker file is there but could not be read (permissions, I/O).
    case unreadable
    /// The marker layer failed some other way.
    case failed

    init(_ error: Error) {
        switch error as? RootMarkerError {
        case .readOnly:   self = .notWritable
        case .malformed:  self = .malformed
        case .unreadable: self = .unreadable
        case nil:         self = .failed
        }
    }

    /// What to tell someone who just tried to copy an archive link. Says what is wrong *and* what
    /// would fix it — "links are unavailable" on its own is the silence we are replacing.
    var message: String {
        switch self {
        case .notWritable:
            return "This archive folder can’t be written to, so a link copied from it wouldn’t survive "
                 + "a relaunch. Give it write access (or move it to a writable volume) and reopen it."
        case .malformed:
            return "This archive folder’s identity file (\(RootMarker.filename)) is damaged, so links "
                 + "can’t be made from it. It was left untouched — restore or remove it, then reopen the folder."
        case .unreadable:
            return "This archive folder’s identity file (\(RootMarker.filename)) can’t be read, so links "
                 + "can’t be made from it. Check its permissions and reopen the folder."
        case .failed:
            return "This archive folder has no usable identity file, so links can’t be made from it. "
                 + "Reopen the folder to try again."
        }
    }
}

/// The granted root's link identity: durable, degraded (with the reason), or no root at all.
enum RootMarkerState: Equatable {
    case noRoot
    case durable(RootMarker)
    case degraded(RootMarkerDegradation)

    /// The marker links may be minted from — `nil` unless the identity is **durable**, i.e. really
    /// on disk. `RootFolderStore.rootMarker` is exactly this, which makes it the single choke point:
    /// every link-minting path in the app already reads it, so a degraded root disables all of them
    /// at once instead of each caller having to remember the check.
    var durableMarker: RootMarker? {
        if case .durable(let marker) = self { return marker }
        return nil
    }

    var degradation: RootMarkerDegradation? {
        if case .degraded(let reason) = self { return reason }
        return nil
    }

    /// Establish the identity of a granted root, creating the marker if it is genuinely absent.
    static func ensuring(_ directory: URL, kind: RootKind = .reader) -> RootMarkerState {
        do {
            return .durable(try RootMarker.ensure(
                at: directory, kind: kind, name: directory.lastPathComponent
            ))
        } catch {
            NSLog("RootMarkerState: no durable identity at \(directory.path): \(error)")
            return .degraded(RootMarkerDegradation(error))
        }
    }

    /// Read — never create — the identity of a root. Used by the UITest fixture path, which must
    /// not write into the fixture.
    static func reading(_ directory: URL) -> RootMarkerState {
        do {
            guard let marker = try RootMarker.read(at: directory) else { return .degraded(.failed) }
            return .durable(marker)
        } catch {
            return .degraded(RootMarkerDegradation(error))
        }
    }
}
