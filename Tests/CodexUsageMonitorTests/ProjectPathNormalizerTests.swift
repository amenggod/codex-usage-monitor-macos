import Foundation
import Testing
@testable import CodexUsageMonitor

@Suite
struct ProjectPathNormalizerTests {
    private let normalizer = ProjectPathNormalizer()

    @Test
    func standardizesPathAndUsesLastComponentAsDisplayName() {
        let identity = normalizer.identity(for: "/synthetic/work/../alpha/.")

        #expect(identity == ProjectIdentity(
            key: "/synthetic/alpha",
            displayName: "alpha",
            fullPath: "/synthetic/alpha"
        ))
    }

    @Test
    func fullPathKeyDistinguishesProjectsWithTheSameDisplayName() {
        let first = normalizer.identity(for: "/synthetic/first/shared-name")
        let second = normalizer.identity(for: "/synthetic/second/shared-name")

        #expect(first.displayName == second.displayName)
        #expect(first.key != second.key)
        #expect(first.fullPath != second.fullPath)
    }

    @Test
    func expandsTildeInSyntheticPath() {
        let identity = normalizer.identity(for: "~/synthetic-work/alpha")
        let expectedPath = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "synthetic-work/alpha")
            .standardizedFileURL.path

        #expect(identity == ProjectIdentity(
            key: expectedPath,
            displayName: "alpha",
            fullPath: expectedPath
        ))
    }

    @Test
    func resolvesSymbolicLinksInTemporaryDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ProjectPathNormalizerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let target = root.appending(path: "target", directoryHint: .isDirectory)
        let link = root.appending(path: "linked-project", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let identity = normalizer.identity(for: link.path)

        #expect(identity == ProjectIdentity(
            key: target.path,
            displayName: "target",
            fullPath: target.path
        ))
    }

    @Test(arguments: [nil, ""] as [String?])
    func missingPathBecomesUnknownProject(_ rawPath: String?) {
        #expect(normalizer.identity(for: rawPath) == ProjectIdentity(
            key: "unknown",
            displayName: "未知项目",
            fullPath: nil
        ))
    }
}
