import ArchiveCore
import Darwin
import Foundation

/// Reader's application-support history. A synchronized intention precedes each companion
/// exchange. Only the verified receipts enter Undo or Redo. One pending intention hides older
/// inverses for that occurrence, leaving the other files' history available after relaunch.
struct CatalogueEditJournal: Sendable {
    typealias Occurrence = CatalogueAssociation.Occurrence

    struct Step: Equatable, Sendable {
        let date: Date
        let title: String
    }

    struct Heads: Sendable {
        var undo: Step?
        var redo: Step?
        var uncertainCount = 0
    }

    struct Group: Sendable {
        let operation: Operation
        var inverses: [CatalogueWriter.Inverse] = []
    }

    struct Operation: Codable, Sendable {
        enum Direction: Codable, Sendable {
            case edit
            case undo(UUID)
            case redo(UUID)

            var source: UUID? {
                switch self {
                case .edit: nil
                case .undo(let id), .redo(let id): id
                }
            }

            var isRedoStep: Bool {
                if case .undo = self { return true }
                return false
            }
        }

        var direction: Direction = .edit
        let title: String
        var id = UUID()
        var date = Date()
    }

    enum Outcome: Codable {
        case unchanged
        case changed(CatalogueWriter.Inverse)
        case refused(String)
        case uncertain(String)
    }

    enum Event: Codable {
        case intent(Operation, Occurrence)
        case result(UUID, Occurrence, Outcome)
    }

    struct Replay {
        private struct Pending: Hashable {
            let group: UUID
            let occurrence: Occurrence
        }

        private var ordered: [UUID] = []
        private var groups: [UUID: Group] = [:]
        private var pending: [Pending: Int] = [:]
        private var at = 0
        private var memberOrder: [Pending: Int] = [:]

        mutating func apply(_ event: Event) {
            at += 1
            switch event {
            case let .intent(operation, occurrence):
                if groups[operation.id] == nil {
                    ordered.append(operation.id)
                    groups[operation.id] = Group(operation: operation)
                }
                if let source = operation.direction.source {
                    groups[source]?.inverses.removeAll { $0.occurrence == occurrence }
                }
                pending[Pending(group: operation.id, occurrence: occurrence)] = at

            case let .result(group, occurrence, outcome):
                let member = Pending(group: group, occurrence: occurrence)
                guard let began = pending[member], let operation = groups[group]?.operation else { return }
                if case .uncertain = outcome { return }
                pending[member] = nil
                guard case .changed(let inverse) = outcome, inverse.occurrence == occurrence else { return }
                if case .edit = operation.direction {
                    for id in ordered where groups[id]?.operation.direction.isRedoStep == true {
                        groups[id]?.inverses.removeAll()
                    }
                }
                groups[group]?.inverses.append(inverse)
                memberOrder[member] = began
            }
        }

        func next(redo: Bool) -> Group? {
            var blocked: [Occurrence: Int] = [:]
            for (member, start) in pending {
                blocked[member.occurrence] = max(blocked[member.occurrence] ?? 0, start)
            }
            for id in ordered.reversed() {
                guard var group = groups[id], group.operation.direction.isRedoStep == redo else { continue }
                group.inverses = group.inverses.filter { inverse in
                    guard let barrier = blocked[inverse.occurrence] else { return true }
                    return (memberOrder[Pending(group: id, occurrence: inverse.occurrence)] ?? 0) > barrier
                }
                if !group.inverses.isEmpty { return group }
            }
            return nil
        }

        var heads: Heads {
            let undo = next(redo: false)?.operation
            let redo = next(redo: true)?.operation
            return Heads(undo: undo.map { Step(date: $0.date, title: $0.title) },
                         redo: redo.map { Step(date: $0.date, title: $0.title) },
                         uncertainCount: Set(pending.keys.map(\.occurrence)).count)
        }
    }

    final class Session {
        private let handle: FileHandle
        private(set) var history: Replay

        fileprivate init(handle: FileHandle, history: Replay) {
            self.handle = handle
            self.history = history
        }

        func record(_ event: Event) throws {
            var line = Data([0x1E])
            line.append(try JSONEncoder().encode(event))
            line.append(0x0A)
            try handle.write(contentsOf: line)
            try AuditLedger.flushToStorage(handle)
            history.apply(event)
        }
    }

    let url: URL

    init(rootID: UUID) {
        url = AuditLedger.defaultFileURL().deletingLastPathComponent()
            .appendingPathComponent("catalogue-edits-\(rootID.uuidString).jsonseq")
    }

    init(url: URL) { self.url = url }

    func read() throws -> Heads {
        try Self.replay(at: url).heads
    }

    func withSession<T>(_ body: (Session) throws -> T) throws -> T {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let handle = try AuditLedger.appendHandle(url, creating: true)
        defer { try? handle.close() }
        guard flock(handle.fileDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { _ = flock(handle.fileDescriptor, LOCK_UN) }
        // Flush the name as well as each subsequent entry; an intention cannot precede the
        // companion write in memory alone, including the first write after installation.
        let folder = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard folder >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(folder) }
        guard fsync(folder) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let session = Session(handle: handle, history: try Self.replay(at: url))
        return try body(session)
    }

    private static func replay(at url: URL) throws -> Replay {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch CocoaError.fileReadNoSuchFile { return Replay() }
        let decoder = JSONDecoder()
        var replay = Replay()
        guard data.isEmpty || data.first == 0x1E else { throw CocoaError(.fileReadCorruptFile) }
        // Each JSON text has an independent start marker and a required final newline. A torn
        // write loses only that fragment even after another app launch appends a new entry.
        // A complete malformed entry must stop history, since it could be the intent for a write.
        for bytes in data.split(separator: 0x1E, omittingEmptySubsequences: true) where bytes.last == 0x0A {
            replay.apply(try decoder.decode(Event.self, from: Data(bytes.dropLast())))
        }
        return replay
    }
}
