/// Commit signing options supported by Gitty.
public struct CommitSigning: Sendable {

    let sign: @Sendable (String) throws -> String

    private init(sign: @escaping @Sendable (String) throws -> String) {
        self.sign = sign
    }

    /// Signs commits with a GPG signature block.
    public static func gpg(_ sign: @escaping @Sendable (String) throws -> String) -> CommitSigning {
        CommitSigning(sign: sign)
    }

    /// Signs commits with an SSH signature block.
    public static func ssh(_ sign: @escaping @Sendable (String) throws -> String) -> CommitSigning {
        CommitSigning(sign: sign)
    }
}
