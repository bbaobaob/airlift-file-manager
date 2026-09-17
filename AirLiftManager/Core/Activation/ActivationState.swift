import Foundation

/// Honest activation states.
/// On-device only these are reachable:
/// NotActivated / TetherRequired / VerificationPending / VerifiedViaTether / Unsupported.
/// The remaining 4 exist for Mac-side tooling / future use and are never set on-device
/// without a verified TetherResult. No on-device exploit is claimed.
enum ActivationState: String, CaseIterable, Equatable {
    case notActivated = "NotActivated"
    case tetherRequired = "TetherRequired"
    case verificationPending = "VerificationPending"
    case verifiedViaTether = "VerifiedViaTether"
    case unsupported = "Unsupported"
    // Mac-side / informational only (never activated on-device without TetherResult):
    case verificationFailed = "VerificationFailed"
    case expired = "Expired"
    case revoked = "Revoked"
    case checking = "Checking"

    /// States reachable by on-device code path.
    static var onDeviceStates: [ActivationState] {
        [.notActivated, .tetherRequired, .verificationPending, .verifiedViaTether, .unsupported]
    }

    var displayName: String { rawValue }
}
