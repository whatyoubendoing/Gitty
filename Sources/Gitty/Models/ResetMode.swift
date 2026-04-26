import libgit2

/// The kind of reset to perform.
public enum ResetMode: Sendable {
    case soft
    case mixed
    case hard
}

extension ResetMode {
    var gitResetMode: git_reset_t {
        switch self {
        case .soft:  return GIT_RESET_SOFT
        case .mixed: return GIT_RESET_MIXED
        case .hard:  return GIT_RESET_HARD
        }
    }
}

