import libgit2

/// A local or remote git branch.
public struct Branch: Sendable, Identifiable, Hashable {

    public var id: String { fullName }

    /// Short name, e.g. `main` or `origin/main`.
    public let name:     String
    /// Full ref name, e.g. `refs/heads/main`.
    public let fullName: String
    public let isRemote: Bool
    /// The tracked remote branch name for local branches, e.g. `origin/main`.
    public let upstreamName: String?
    /// OID of the commit this branch points to.
    public let tipID:    OID

    // MARK: - Internal

    init(name: String, fullName: String, isRemote: Bool, upstreamName: String? = nil, tipID: OID) {
        self.name     = name
        self.fullName = fullName
        self.isRemote = isRemote
        self.upstreamName = upstreamName
        self.tipID    = tipID
    }

    init?(pointer: OpaquePointer) {
        guard let fullCStr = git_reference_name(pointer) else { return nil }
        let full = String(cString: fullCStr)

        var nameCStr: UnsafePointer<CChar>?
        guard git_branch_name(&nameCStr, pointer) == 0, let nameCStr else { return nil }

        var obj: OpaquePointer?
        guard git_reference_peel(&obj, pointer, GIT_OBJECT_COMMIT) == 0, let obj else { return nil }
        let tip = git_commit_id(obj).map { OID(raw: $0.pointee) }
        git_object_free(obj)
        guard let tip else { return nil }

        let isRemote = full.hasPrefix("refs/remotes/")
        var upstreamName: String?
        if !isRemote {
            var upstreamPtr: OpaquePointer?
            if git_branch_upstream(&upstreamPtr, pointer) == 0, let upstreamPtr {
                defer { git_reference_free(upstreamPtr) }
                var upstreamNameCStr: UnsafePointer<CChar>?
                if git_branch_name(&upstreamNameCStr, upstreamPtr) == 0, let upstreamNameCStr {
                    upstreamName = String(cString: upstreamNameCStr)
                }
            }
        }

        self.name     = String(cString: nameCStr)
        self.fullName = full
        self.isRemote = isRemote
        self.upstreamName = upstreamName
        self.tipID    = tip
    }
}
