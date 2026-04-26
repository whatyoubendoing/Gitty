import XCTest
@testable import Gitty

final class RemoteTests: XCTestCase {

    private func withRepos(_ body: (URL, Repository, URL) throws -> Void) throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("GittyRemoteTests-\(UUID().uuidString)")
        let repoDir = base.appendingPathComponent("repo")
        let bareDir = base.appendingPathComponent("bare.git")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bareDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let repo = try Repository.initialize(at: repoDir)
        _ = try Repository.initialize(at: bareDir, bare: true)
        try body(repoDir, repo, bareDir)
    }

    private func withReposAsync(_ body: (URL, Repository, URL) async throws -> Void) async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("GittyRemoteTests-\(UUID().uuidString)")
        let repoDir = base.appendingPathComponent("repo")
        let bareDir = base.appendingPathComponent("bare.git")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bareDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let repo = try Repository.initialize(at: repoDir)
        _ = try Repository.initialize(at: bareDir, bare: true)
        try await body(repoDir, repo, bareDir)
    }

    private func seedInitialCommit(in repo: Repository, at repoDir: URL) throws {
        try "hello".write(to: repoDir.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        try repo.stage(paths: ["file.txt"])
        try repo.commit(message: "init", author: Signature(name: "Test", email: "test@gitty.dev"))
    }

    func testAddRemote() throws {
        try withRepos { _, repo, bareDir in
            let remote = try repo.remotes.add(name: "origin", url: bareDir.path)
            XCTAssertEqual(remote.name, "origin")
            XCTAssertEqual(remote.url, bareDir.path)
        }
    }

    func testListRemotes() throws {
        try withRepos { _, repo, bareDir in
            try repo.remotes.add(name: "origin", url: bareDir.path)
            let remotes = try repo.remotes.list()
            XCTAssertTrue(remotes.contains { $0.name == "origin" })
        }
    }

    func testRemoveRemote() throws {
        try withRepos { _, repo, bareDir in
            try repo.remotes.add(name: "origin", url: bareDir.path)
            try repo.remotes.remove(named: "origin")
            let remotes = try repo.remotes.list()
            XCTAssertFalse(remotes.contains { $0.name == "origin" })
        }
    }

    func testRenameRemote() throws {
        try withRepos { _, repo, bareDir in
            try repo.remotes.add(name: "origin", url: bareDir.path)
            try repo.remotes.rename(from: "origin", to: "upstream")
            let remotes = try repo.remotes.list()
            XCTAssertTrue(remotes.contains { $0.name == "upstream" })
            XCTAssertFalse(remotes.contains { $0.name == "origin" })
        }
    }

    func testPushExplicitRefspecs() async throws {
        try await withReposAsync { repoDir, repo, bareDir in
            try seedInitialCommit(in: repo, at: repoDir)
            try repo.remotes.add(name: "origin", url: bareDir.path)

            try await repo.remotes.push(
                refspecs: ["refs/heads/master:refs/heads/pushed-with-refspec"],
                to: "origin",
                credentials: .default
            )

            let bareRepo = try Repository.open(at: bareDir)
            XCTAssertTrue(try bareRepo.branches.list().contains { $0.name == "pushed-with-refspec" })
        }
    }

    func testDeleteRemoteBranch() async throws {
        try await withReposAsync { repoDir, repo, bareDir in
            try seedInitialCommit(in: repo, at: repoDir)
            try repo.remotes.add(name: "origin", url: bareDir.path)

            try await repo.remotes.push(
                refspecs: ["refs/heads/master:refs/heads/delete-me"],
                to: "origin",
                credentials: .default
            )
            var bareRepo = try Repository.open(at: bareDir)
            XCTAssertTrue(try bareRepo.branches.list().contains { $0.name == "delete-me" })
            bareRepo = try Repository.open(at: bareDir)

            try await repo.remotes.deleteBranch(named: "delete-me", from: "origin", credentials: .default)

            let branches = try bareRepo.branches.list()
            XCTAssertFalse(branches.contains { $0.name == "delete-me" })
        }
    }
}
