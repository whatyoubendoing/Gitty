import libgit2

extension Repository {

    /// Commits whatever is currently staged in the index.
    ///
    /// Call `stage(paths:)` or `stageAll()` before this if you need to change
    /// what is included.
    ///
    /// ```swift
    /// try repo.stage(paths: ["Sources/Login.swift"])
    /// let commit = try repo.commit(
    ///     message: "feat: add login screen",
    ///     author: Signature(name: "Alice", email: "alice@example.com")
    /// )
    /// ```
    ///
    /// Pass `signing` to attach a GPG or SSH signature produced by your own
    /// signer. The closure receives the canonical commit content and must
    /// return the armored signature block.
    @discardableResult
    public func commit(
        message: String,
        author: Signature,
        signing: CommitSigning? = nil
    ) throws -> Commit {
        let idx = try openIndex()

        var treeOID = git_oid()
        guard git_index_write_tree(&treeOID, idx.raw) == 0 else {
            throw GittyError(message: "Could not write tree from index")
        }
        var treePtr: OpaquePointer?
        guard git_tree_lookup(&treePtr, pointer, &treeOID) == 0, let treePtr else {
            throw GittyError(message: "Could not look up tree")
        }
        let tree = GitPointer.tree(treePtr)

        let sigPtr  = try author.makePointer()
        let sig     = GitPointer.signature(sigPtr)

        let parentCommit = headCommitPointer(in: pointer)
        var parents: [OpaquePointer?] = parentCommit.map { [$0.raw] } ?? []

        var commitOID = git_oid()

        if let signing {
            var buffer = git_buf()
            defer { git_buf_dispose(&buffer) }

            let code = parents.withUnsafeMutableBufferPointer { buf in
                git_commit_create_buffer(&buffer, pointer,
                                         sigPtr, sigPtr, nil, message, tree.raw,
                                         buf.count, buf.baseAddress)
            }
            guard code == 0, let contentPtr = buffer.ptr else {
                throw GittyError(code: code)
            }

            let content = String(cString: contentPtr)
            let signature = try signing.sign(content)
            let signedCode = git_commit_create_with_signature(
                &commitOID, pointer, content, signature, nil
            )
            guard signedCode == 0 else { throw GittyError(code: signedCode) }

            try moveHEAD(to: &commitOID, message: "commit: \(message)")
        } else {
            let code = parents.withUnsafeMutableBufferPointer { buf in
                git_commit_create(&commitOID, pointer, "HEAD",
                                  sigPtr, sigPtr, nil, message, tree.raw,
                                  buf.count, buf.baseAddress)
            }
            guard code == 0 else { throw GittyError(code: code) }
        }

        _ = sig  // keep alive

        let commitPtr = try lookupCommitPointer(oid: &commitOID, in: pointer)
        return Commit(pointer: commitPtr.raw)
    }

    /// Advances HEAD to the given OID. Handles both born and unborn branches
    /// via the symbolic target, falling back to a detached HEAD update.
    private func moveHEAD(to oid: inout git_oid, message: String) throws {
        var headRef: OpaquePointer?
        guard git_reference_lookup(&headRef, pointer, "HEAD") == 0, let headRef else {
            let code = git_repository_set_head_detached(pointer, &oid)
            guard code == 0 else { throw GittyError(code: code) }
            return
        }
        let head = GitPointer.reference(headRef)

        if let symbolic = git_reference_symbolic_target(head.raw) {
            var newRef: OpaquePointer?
            let code = git_reference_create(&newRef, pointer,
                                            String(cString: symbolic),
                                            &oid, 1, message)
            if let newRef { git_reference_free(newRef) }
            guard code == 0 else { throw GittyError(code: code) }
        } else {
            var updated: OpaquePointer?
            let code = git_reference_set_target(&updated, head.raw, &oid, message)
            if let updated { git_reference_free(updated) }
            guard code == 0 else { throw GittyError(code: code) }
        }
    }
}
