import libgit2

extension Repository {

    /// Resets the repository to `target`.
    public func reset(_ mode: ResetMode, to target: String = "HEAD") throws {
        var targetObject: OpaquePointer?
        let lookupCode = git_revparse_single(&targetObject, pointer, target)
        guard lookupCode == 0, let targetObject else { throw GittyError(code: lookupCode) }
        defer { git_object_free(targetObject) }

        let code = git_reset(pointer, targetObject, mode.gitResetMode, nil)
        guard code == 0 else { throw GittyError(code: code) }
    }
}
