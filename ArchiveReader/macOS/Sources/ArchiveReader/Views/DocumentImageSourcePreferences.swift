import Foundation
import CryptoKit

enum DocumentImageSource: String, Sendable {
    case pdf
    case jpeg
}

/// Small per-document preference store. The key uses the durable root GUID and the exact relative PDF
/// path, so it survives relaunches and moving the archive while staying isolated between archives.
@MainActor
final class DocumentImageSourcePreferences {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func source(rootGUID: UUID, relativePath: String) -> DocumentImageSource {
        guard let value = defaults.string(forKey: key(rootGUID: rootGUID, relativePath: relativePath)),
              let source = DocumentImageSource(rawValue: value) else { return .pdf }
        return source
    }

    func set(_ source: DocumentImageSource, rootGUID: UUID, relativePath: String) {
        let key = key(rootGUID: rootGUID, relativePath: relativePath)
        if source == .pdf { defaults.removeObject(forKey: key) }
        else { defaults.set(source.rawValue, forKey: key) }
    }

    private func key(rootGUID: UUID, relativePath: String) -> String {
        var identity = Data(rootGUID.uuidString.lowercased().utf8)
        identity.append(0)
        identity.append(contentsOf: relativePath.utf8)
        let digest = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
        return "ar.documentImageSource.\(digest)"
    }
}
