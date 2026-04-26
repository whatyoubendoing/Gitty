import XCTest
@testable import Gitty

final class RepositoryTests: XCTestCase {

    private func withTempDir(_ body: (URL) throws -> Void) throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("GittyTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try body(tmp)
    }

    private func withTempDirAsync(_ body: (URL) async throws -> Void) async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("GittyTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try await body(tmp)
    }

    private func write(_ content: String, to name: String, in dir: URL) throws {
        try content.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func headCommitID(in repo: Repository) async throws -> OID {
        for try await commit in repo.log(limit: 1) {
            return commit.id
        }
        throw GittyError(message: "Could not resolve HEAD")
    }

    private static func signatureBlock(prefix: String, content: String) -> String {
        let checksum = content.utf8.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1) }
        return """
        -----BEGIN \(prefix) SIGNATURE-----
        test-signature-\(checksum)
        -----END \(prefix) SIGNATURE-----
        """
    }

    private let author = Signature(name: "Test", email: "test@gitty.dev")

    // MARK: - Initialize / open

    func testInitializeCreatesRepo() throws {
        try withTempDir { dir in
            let repo = try Repository.initialize(at: dir)
            XCTAssertTrue(Repository.exists(at: dir))
            XCTAssertEqual(repo.workingDirectory.resolvingSymlinksInPath(), dir.resolvingSymlinksInPath())
        }
    }

    func testExistsReturnsFalse() {
        XCTAssertFalse(Repository.exists(at: URL(fileURLWithPath: "/tmp/no-such-repo-\(UUID())")))
    }

    func testOpenExisting() throws {
        try withTempDir { dir in
            try Repository.initialize(at: dir)
            let repo = try Repository.open(at: dir)
            XCTAssertEqual(repo.workingDirectory.resolvingSymlinksInPath(), dir.resolvingSymlinksInPath())
        }
    }

    // MARK: - Stage + Commit

    func testStageAndCommit() throws {
        try withTempDir { dir in
            let repo = try Repository.initialize(at: dir)
            try write("hello", to: "a.txt", in: dir)

            try repo.stage(paths: ["a.txt"])
            let commit = try repo.commit(message: "Initial commit", author: author)

            XCTAssertEqual(commit.subject, "Initial commit")
            XCTAssertEqual(commit.author.name, "Test")
            XCTAssertTrue(commit.parentIDs.isEmpty)
            XCTAssertEqual(commit.id.sha.count, 40)
            XCTAssertFalse(commit.isSigned)
            XCTAssertNil(commit.signature)
        }
    }

    func testCommitWithGPGSignature() async throws {
        try await withTempDirAsync { dir in
            let repo = try Repository.initialize(at: dir)
            try write("hello", to: "a.txt", in: dir)
            try repo.stage(paths: ["a.txt"])

            let signature: @Sendable (String) -> String = { Self.signatureBlock(prefix: "PGP", content: $0) }
            let commit = try repo.commit(
                message: "signed commit",
                author: author,
                signing: .gpg(signature)
            )

            let extracted = try XCTUnwrap(commit.signature)
            XCTAssertEqual(extracted.block, signature(extracted.signedContent))
            XCTAssertTrue(commit.isSigned)
            let headID = try await headCommitID(in: repo)
            XCTAssertEqual(headID, commit.id)
        }
    }

    func testCommitWithSSHSignature() async throws {
        try await withTempDirAsync { dir in
            let repo = try Repository.initialize(at: dir)
            try write("hello", to: "a.txt", in: dir)
            try repo.stage(paths: ["a.txt"])
            let parent = try repo.commit(message: "initial commit", author: author)

            try write("hello again", to: "a.txt", in: dir)
            try repo.stage(paths: ["a.txt"])
            let signature: @Sendable (String) -> String = { Self.signatureBlock(prefix: "SSH", content: $0) }
            let commit = try repo.commit(
                message: "ssh signed commit",
                author: author,
                signing: .ssh(signature)
            )

            let extracted = try XCTUnwrap(commit.signature)
            XCTAssertEqual(extracted.block, signature(extracted.signedContent))
            XCTAssertTrue(commit.isSigned)
            let headID = try await headCommitID(in: repo)
            XCTAssertEqual(headID, commit.id)
            XCTAssertEqual(commit.parentIDs, [parent.id])
        }
    }

    func testUnstageNewFile() throws {
        try withTempDir { dir in
            let repo = try Repository.initialize(at: dir)
            try write("hello", to: "a.txt", in: dir)
            try repo.stage(paths: ["a.txt"])

            // Before unstage: file should be staged (.added)
            let before = try repo.status(includeUntracked: false)
            XCTAssertTrue(before.contains { $0.path == "a.txt" && $0.status == .added })

            try repo.unstage(paths: ["a.txt"])

            // After unstage with no HEAD: file is removed from index → shows as untracked
            let after = try repo.status(includeUntracked: true)
            XCTAssertTrue(after.contains { $0.path == "a.txt" && $0.status == .untracked })
        }
    }

    func testUnstageTrackedFile() throws {
        try withTempDir { dir in
            let repo = try Repository.initialize(at: dir)
            try write("v1", to: "a.txt", in: dir)
            try repo.stage(paths: ["a.txt"])
            try repo.commit(message: "init", author: author)

            // Modify and stage
            try write("v2", to: "a.txt", in: dir)
            try repo.stage(paths: ["a.txt"])

            // Before unstage: index differs from HEAD (staged diff is non-empty)
            let diffBefore = try repo.diff(from: "HEAD")
            XCTAssertTrue(diffBefore.contains { $0.newPath == "a.txt" })

            try repo.unstage(paths: ["a.txt"])

            // After unstage: index matches HEAD (no staged diff), change is in working tree only
            let diffAfter = try repo.diff()  // index → workdir
            XCTAssertTrue(diffAfter.contains { $0.newPath == "a.txt" })
        }
    }

    func testStageTrackedFileWithSpecialCharactersOnlyStagesSelectedPath() throws {
        try withTempDir { dir in
            let repo = try Repository.initialize(at: dir)

            let targetPath = "src/app/(app)/project/[projectId]/settings/page.tsx"
            let siblingPath = "src/app/(app)/project/[projectId]/integrations/page.tsx"

            for path in [targetPath, siblingPath] {
                let url = dir.appendingPathComponent(path)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try "export default function Page() { return null }\n".write(
                    to: url,
                    atomically: true,
                    encoding: .utf8
                )
            }

            try repo.stage(paths: [targetPath, siblingPath])
            try repo.commit(message: "init", author: author)

            try write("export default function Page() { return 'settings' }\n", to: targetPath, in: dir)
            try write("export default function Page() { return 'integrations' }\n", to: siblingPath, in: dir)

            try repo.stage(paths: [targetPath])

            let diffAfter = try repo.diff()
            XCTAssertFalse(diffAfter.contains { $0.newPath == targetPath })
            XCTAssertTrue(diffAfter.contains { $0.newPath == siblingPath })
        }
    }

    func testUnstageTrackedFileWithSpecialCharactersOnlyUnstagesSelectedPath() throws {
        try withTempDir { dir in
            let repo = try Repository.initialize(at: dir)

            let targetPath = "src/app/(app)/project/[projectId]/settings/page.tsx"
            let siblingPath = "src/app/(app)/project/[projectId]/integrations/page.tsx"

            for path in [targetPath, siblingPath] {
                let url = dir.appendingPathComponent(path)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try "export default function Page() { return null }\n".write(
                    to: url,
                    atomically: true,
                    encoding: .utf8
                )
            }

            try repo.stage(paths: [targetPath, siblingPath])
            try repo.commit(message: "init", author: author)

            try write("export default function Page() { return 'settings' }\n", to: targetPath, in: dir)
            try write("export default function Page() { return 'integrations' }\n", to: siblingPath, in: dir)
            try repo.stage(paths: [targetPath, siblingPath])

            try repo.unstage(paths: [targetPath])

            let diffAfter = try repo.diff()
            XCTAssertTrue(diffAfter.contains { $0.newPath == targetPath })
            XCTAssertFalse(diffAfter.contains { $0.newPath == siblingPath })
        }
    }

    func testCommitChain() throws {
        try withTempDir { dir in
            let repo = try Repository.initialize(at: dir)
            try write("A", to: "a.txt", in: dir)
            try repo.stage(paths: ["a.txt"])
            let first = try repo.commit(message: "First", author: author)

            try write("B", to: "b.txt", in: dir)
            try repo.stage(paths: ["b.txt"])
            let second = try repo.commit(message: "Second", author: author)

            XCTAssertEqual(second.parentIDs, [first.id])
        }
    }

    func testStageAll() throws {
        try withTempDir { dir in
            let repo = try Repository.initialize(at: dir)
            try write("v1", to: "file.txt", in: dir)
            try repo.stage(paths: ["file.txt"])
            try repo.commit(message: "init", author: author)

            try write("v2", to: "file.txt", in: dir)
            try write("new", to: "new.txt", in: dir)
            try repo.stageAll()
            let commit = try repo.commit(message: "stage all", author: author)
            XCTAssertEqual(commit.subject, "stage all")
        }
    }

    func testResetHardRestoresTrackedChanges() throws {
        try withTempDir { dir in
            let repo = try Repository.initialize(at: dir)
            try write("v1", to: "file.txt", in: dir)
            try repo.stage(paths: ["file.txt"])
            try repo.commit(message: "init", author: author)

            try write("v2", to: "file.txt", in: dir)
            try repo.stage(paths: ["file.txt"])

            try repo.reset(.hard)

            let content = try String(contentsOf: dir.appendingPathComponent("file.txt"), encoding: .utf8)
            XCTAssertEqual(content, "v1")
            XCTAssertTrue(try repo.status().isEmpty)
        }
    }

    func testResetHardLeavesUntrackedFilesForCallerOwnedCleanup() throws {
        try withTempDir { dir in
            let repo = try Repository.initialize(at: dir)
            try write("v1", to: "tracked.txt", in: dir)
            try repo.stage(paths: ["tracked.txt"])
            try repo.commit(message: "init", author: author)

            try write("v2", to: "tracked.txt", in: dir)
            try write("staged new", to: "staged-new.txt", in: dir)
            try write("untracked", to: "untracked.txt", in: dir)
            try repo.stage(paths: ["tracked.txt", "staged-new.txt"])

            try repo.reset(.hard)

            let trackedContent = try String(contentsOf: dir.appendingPathComponent("tracked.txt"), encoding: .utf8)
            XCTAssertEqual(trackedContent, "v1")
            XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("staged-new.txt").path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("untracked.txt").path))
            let status = try repo.status()
            XCTAssertEqual(status.count, 1)
            XCTAssertTrue(status.contains { $0.path == "untracked.txt" && $0.status == .untracked })
        }
    }

    func testRestoreRestoresTrackedFileAcrossStagedAndUnstagedChanges() throws {
        try withTempDir { dir in
            let repo = try Repository.initialize(at: dir)
            try write("v1\n", to: "file.txt", in: dir)
            try repo.stage(paths: ["file.txt"])
            try repo.commit(message: "init", author: author)

            try write("v2\n", to: "file.txt", in: dir)
            try repo.stage(paths: ["file.txt"])
            try write("v3\n", to: "file.txt", in: dir)

            try repo.restore(paths: ["file.txt"])

            let content = try String(contentsOf: dir.appendingPathComponent("file.txt"), encoding: .utf8)
            XCTAssertEqual(content, "v1\n")
            XCTAssertTrue(try repo.status().isEmpty)
        }
    }

    func testRestoreWithSpecialCharactersOnlyRestoresSelectedPath() throws {
        try withTempDir { dir in
            let repo = try Repository.initialize(at: dir)

            let targetPath = "src/app/(app)/project/[projectId]/settings/page.tsx"
            let siblingPath = "src/app/(app)/project/[projectId]/integrations/page.tsx"

            for path in [targetPath, siblingPath] {
                let url = dir.appendingPathComponent(path)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try "export default function Page() { return null }\n".write(
                    to: url,
                    atomically: true,
                    encoding: .utf8
                )
            }

            try repo.stage(paths: [targetPath, siblingPath])
            try repo.commit(message: "init", author: author)

            try write("export default function Page() { return 'settings' }\n", to: targetPath, in: dir)
            try write("export default function Page() { return 'integrations' }\n", to: siblingPath, in: dir)

            try repo.restore(paths: [targetPath])

            let targetContent = try String(
                contentsOf: dir.appendingPathComponent(targetPath),
                encoding: .utf8
            )
            let siblingContent = try String(
                contentsOf: dir.appendingPathComponent(siblingPath),
                encoding: .utf8
            )
            XCTAssertEqual(targetContent, "export default function Page() { return null }\n")
            XCTAssertEqual(siblingContent, "export default function Page() { return 'integrations' }\n")
        }
    }

    // MARK: - Status

    func testStatusModified() throws {
        try withTempDir { dir in
            let repo = try Repository.initialize(at: dir)
            try write("v1", to: "f.txt", in: dir)
            try repo.stage(paths: ["f.txt"])
            try repo.commit(message: "init", author: author)

            try write("v2", to: "f.txt", in: dir)
            let entries = try repo.status()
            XCTAssertTrue(entries.contains { $0.path == "f.txt" && $0.status == .modified })
        }
    }

    func testStatusUntracked() throws {
        try withTempDir { dir in
            let repo = try Repository.initialize(at: dir)
            try write("x", to: "new.txt", in: dir)
            let entries = try repo.status()
            XCTAssertTrue(entries.contains { $0.path == "new.txt" && $0.status == .untracked })
        }
    }

    // MARK: - OID

    func testOIDRoundTrip() throws {
        try withTempDir { dir in
            let repo = try Repository.initialize(at: dir)
            try write("x", to: "x.txt", in: dir)
            try repo.stage(paths: ["x.txt"])
            let commit = try repo.commit(message: "test", author: author)

            XCTAssertEqual(commit.id.sha.count, 40)
            XCTAssertEqual(commit.id.abbreviated.count, 7)

            let reconstructed = OID(string: commit.id.sha)
            XCTAssertEqual(reconstructed, commit.id)
        }
    }

    // MARK: - Branches

    func testBranchCreate() throws {
        try withTempDir { dir in
            let repo = try Repository.initialize(at: dir)
            try write("a", to: "a.txt", in: dir)
            try repo.stage(paths: ["a.txt"])
            let commit = try repo.commit(message: "init", author: author)

            let branch = try repo.branches.create(named: "feature", at: commit)
            XCTAssertEqual(branch.name, "feature")
            XCTAssertEqual(branch.tipID, commit.id)
        }
    }

    func testBranchList() throws {
        try withTempDir { dir in
            let repo = try Repository.initialize(at: dir)
            try write("a", to: "a.txt", in: dir)
            try repo.stage(paths: ["a.txt"])
            try repo.commit(message: "init", author: author)

            let branches = try repo.branches.list()
            XCTAssertFalse(branches.isEmpty)
        }
    }
}
