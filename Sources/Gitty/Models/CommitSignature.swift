/// The signature attached to a signed commit.
///
/// Use `block` together with `signedContent` to verify the commit with an
/// external GPG or SSH verifier.
public struct CommitSignature: Sendable, Equatable {

    /// The armored signature block (e.g. `-----BEGIN PGP SIGNATURE-----…`).
    public let block: String

    /// The canonical commit content that was signed.
    public let signedContent: String

    public init(block: String, signedContent: String) {
        self.block = block
        self.signedContent = signedContent
    }
}
