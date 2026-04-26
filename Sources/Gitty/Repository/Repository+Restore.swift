import libgit2

extension Repository {

    /// Restores the specified paths from `target` in both the index and working tree.
    ///
    /// This is the path-scoped equivalent of restoring files back to `HEAD` without
    /// touching unrelated changes elsewhere in the repository.
    public func restore(paths: [String], from target: String = "HEAD") throws {
        guard !paths.isEmpty else { return }

        var targetObject: OpaquePointer?
        let lookupCode = git_revparse_single(&targetObject, pointer, target)
        guard lookupCode == 0, let targetObject else { throw GittyError(code: lookupCode) }
        defer { git_object_free(targetObject) }

        let resetCode = withPathspecs(paths) { pathspecs -> Int32 in
            git_reset_default(pointer, targetObject, &pathspecs)
        }
        guard resetCode == 0 else {
            throw GittyError(message: "Could not restore selected files in index")
        }

        var treeObject: OpaquePointer?
        let peelCode = git_object_peel(&treeObject, targetObject, GIT_OBJECT_TREE)
        guard peelCode == 0, let treeObject else { throw GittyError(code: peelCode) }
        defer { git_object_free(treeObject) }

        var opts = git_checkout_options()
        git_checkout_init_options(&opts, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
        opts.checkout_strategy =
            GIT_CHECKOUT_FORCE.rawValue
            | GIT_CHECKOUT_RECREATE_MISSING.rawValue
            | GIT_CHECKOUT_REMOVE_UNTRACKED.rawValue

        let checkoutCode = withPathspecs(paths) { pathspecs -> Int32 in
            opts.paths = pathspecs
            return git_checkout_tree(pointer, treeObject, &opts)
        }
        guard checkoutCode == 0 else {
            throw GittyError(message: "Could not restore selected files in working tree")
        }
    }
}
