import Foundation

/// The connection setup ladder required by the product spec:
/// disconnected → vpnRequired → vpnConnected → pairingRequired →
/// pairingImported → transportChecking → transportReady →
/// capabilityChecking → ready   (failed from any checkable step)
///
/// Rules enforced here:
/// - Every transition is driven by a REAL check result; nothing is simulated.
/// - A TCP connect is not filesystem access; pairing presence is not transport
///   proof; only `ready` (after a verified lockdown exchange + capability
///   probe) unlocks AirLift-dependent features.
/// - `ready` is never persisted as a permanent truth: the ladder is re-run
///   each launch and features re-gate themselves accordingly.
enum ConnectionPhase: String, Codable, CaseIterable {
    case disconnected
    case vpnRequired
    case vpnConnected
    case pairingRequired
    case pairingImported
    case transportChecking
    case transportReady
    case capabilityChecking
    case ready
    case failed

    /// Ordered check ladder (entry state first, terminal `ready` last).
    static let ladder: [ConnectionPhase] = [
        .disconnected, .vpnRequired, .vpnConnected, .pairingRequired, .pairingImported,
        .transportChecking, .transportReady, .capabilityChecking, .ready,
    ]

    var isTerminal: Bool { self == .ready || self == .failed }
    var isRunning: Bool { self == .transportChecking || self == .capabilityChecking }

    /// AirLift-dependent features unlock only after full verification.
    var allowsAirLiftFeatures: Bool { self == .ready }

    /// Sandbox Files tab features never depend on the connection gate.
    var allowsSandboxFeatures: Bool { true }

    /// The next phase the ladder moves to when a check passes.
    func advanced() -> ConnectionPhase? {
        guard let index = Self.ladder.firstIndex(of: self), index + 1 < Self.ladder.count else {
            return nil
        }
        return Self.ladder[index + 1]
    }
}

/// Pure state-machine core, unit-tested independently of any UI or I/O.
struct ConnectionMachine: Equatable {
    private(set) var phase: ConnectionPhase = .disconnected
    private(set) var failureReason: String?

    init(initial: ConnectionPhase = .disconnected) {
        phase = initial
    }

    /// Applies a successful step transition; returns false if the move is illegal.
    @discardableResult
    mutating func advance() -> Bool {
        guard let next = phase.advanced() else { return false }
        phase = next
        failureReason = nil
        return true
    }

    /// Any checkable step can fail with a recorded reason.
    mutating func fail(_ reason: String) {
        phase = .failed
        failureReason = reason
    }

    mutating func reset() {
        phase = .disconnected
        failureReason = nil
    }

    /// Illegal-jump guard used by tests: can the machine accept this phase?
    static func canReach(_ target: ConnectionPhase, from current: ConnectionPhase) -> Bool {
        guard let currentIndex = ConnectionPhase.ladder.firstIndex(of: current),
              let targetIndex = ConnectionPhase.ladder.firstIndex(of: target) else {
            return false
        }
        return targetIndex == currentIndex + 1
    }
}

/// One observable check step rendered by the setup screen.
struct ConnectionCheckStep: Identifiable, Equatable {
    enum Status: String, Equatable {
        case pending, running, passed, failed, waitingForUser
    }

    let id: ConnectionPhase
    var title: String
    var status: Status = .pending
    var detail: String = ""
}
