import Testing
import Foundation
@testable import ArchiveNotes

struct OrganizationFileTests {
    @Test func roundTrip() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("org-file-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let folderId = UUID()
        let itemId = UUID()
        let templateId = UUID()
        let now = Date()

        let folders = [
            VFolder(id: folderId, name: "Test Folder", parentId: nil,
                    sortOrder: 0, kind: .normal, queryJSON: nil),
            VFolder(id: UUID(), name: "Smart", parentId: folderId,
                    sortOrder: 1, kind: .smart, queryJSON: "{\"searchText\":\"hello\"}")
        ]
        let memberships = [
            Membership(itemId: itemId, folderId: folderId, addedAt: now)
        ]
        let assignments = [
            TemplateAssignment(folderId: folderId, templateId: templateId)
        ]

        OrganizationFile.export(folders: folders, memberships: memberships,
                                assignments: assignments, to: tmp)

        let result = OrganizationFile.load(from: tmp)
        #expect(result != nil)
        guard let r = result else { return }

        #expect(r.folders.count == 2)
        #expect(r.folders[0].id == folders[0].id)
        #expect(r.folders[0].name == "Test Folder")
        #expect(r.folders[1].kind == .smart)
        #expect(r.folders[1].queryJSON == "{\"searchText\":\"hello\"}")

        #expect(r.memberships.count == 1)
        #expect(r.memberships[0].itemId == itemId)
        #expect(r.memberships[0].folderId == folderId)
        // Date round-trip within 1 second (epoch seconds precision)
        #expect(abs(r.memberships[0].addedAt.timeIntervalSince(now)) < 1)

        #expect(r.assignments.count == 1)
        #expect(r.assignments[0].folderId == folderId)
        #expect(r.assignments[0].templateId == templateId)
    }

    @Test func loadMissingFileReturnsNil() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("org-file-missing-\(UUID().uuidString)")
        #expect(OrganizationFile.load(from: tmp) == nil)
    }

    @Test func atomicWriteProducesFile() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("org-file-atomic-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        OrganizationFile.export(folders: [], memberships: [], assignments: [], to: tmp)
        let jsonURL = tmp.appendingPathComponent("organization.json")
        #expect(FileManager.default.fileExists(atPath: jsonURL.path))

        // Verify it's valid JSON with schema field
        let data = try Data(contentsOf: jsonURL)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["schema"] as? Int == 1)
    }
}
