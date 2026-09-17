import Foundation

/// Activation state machine with durable persistence and launch re-verification.
///
/// Design rules honored here:
/// - `activated` is only ever reached when a probe verified the channel.
/// - A persisted `activated` is never trusted blindly: every launch re-runs
///   verification and downgrades to `disconnected`/`unsupported` if reality says so.
/// - Failed attempts keep the full reason for display and logging.
@MainActor
final class ActivationManager: ObservableObject {
    @Published private(set) var state: AirLiftState
    @Published private(set) var lastMessage: String
    @Published private(set) var lastVerifiedAt: Date?
    @Published var isBusy: Bool = false

    private let probe: AirLiftProbing
    private let persistence: PersistenceService

    init(probe: AirLiftProbing,
         persistence: PersistenceService,
         initialState: AirLiftState? = nil) {
        self.probe = probe
        self.persistence = persistence
        // Restore last known state, but treat it as "last reported", never as truth.
        if let raw = persistence.string(forKey: .activationStateRaw),
           let restored = AirLiftState(rawValue: raw) {
            self.state = initialState ?? restored
        } else {
            self.state = initialState ?? .notActivated
        }
        self.lastVerifiedAt = persistence.date(forKey: .activationLastVerified)
        self.lastMessage = persistence.string(forKey: .activationLastResult)
            ?? "No activation attempt recorded yet."
        AppLogger.airLift.info("ActivationManager init, restored state: \(state.rawValue, privacy: .public)")
    }

    // MARK: - Transitions

    private func transition(to newState: AirLiftState, message: String? = nil) {
        state = newState
        if let message {
            lastMessage = message
            persistence.setString(message, forKey: .activationLastResult)
        }
        persistence.setString(newState.rawValue, forKey: .activationStateRaw)
        AppLogger.airLift.info("State -> \(newState.rawValue, privacy: .public)")
    }

    private func markVerified() {
        lastVerifiedAt = Date()
        persistence.setDate(lastVerifiedAt, forKey: .activationLastVerified)
    }

    /// Full activation attempt: preparing -> connecting -> activating -> verifying -> terminal.
    func activate() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        transition(to: .preparing, message: "Preparing activation attempt…")
        try? await Task.sleep(nanoseconds: 150_000_000) // brief UI-visible transition

        transition(to: .connecting, message: "Checking environment for AirLift components…")
        let result = await probe.probe()

        switch result {
        case .activated(let detail):
            transition(to: .verifying, message: "Verifying AirLift channel…")
            transition(to: .activated, message: detail)
            markVerified()
        case .unsupported(let reason):
            transition(to: .unsupported, message: reason)
            markVerified()
        case .failed(let reason):
            transition(to: .failed, message: reason)
        case .disconnected(let reason):
            transition(to: .disconnected, message: reason)
        }
    }

    /// Called on every app launch. Re-verification is mandatory; the persisted
    /// flag alone is never treated as evidence that AirLift still works.
    func verifyOnLaunch() async {
        guard !isBusy else { return }
        guard state.isTerminal else { return } // don't stomp an in-flight attempt

        if state == .notActivated || state == .failed || state == .unsupported {
            // Nothing to protect: run a quick probe so status reflects reality.
            isBusy = true
            defer { isBusy = false }
            transition(to: .connecting, message: "Checking AirLift availability on launch…")
            let result = await probe.probe()
            switch result {
            case .activated(let detail):
                transition(to: .activated, message: detail)
                markVerified()
            case .unsupported(let reason):
                transition(to: .unsupported, message: reason)
                markVerified()
            case .failed(let reason):
                transition(to: .failed, message: reason)
            case .disconnected(let reason):
                transition(to: .disconnected, message: reason)
            }
            return
        }

        // Previously believed active: verify before continuing to claim it.
        isBusy = true
        defer { isBusy = false }
        transition(to: .verifying, message: "Re-verifying persisted activation state…")
        let result = await probe.probe()
        switch result {
        case .activated(let detail):
            transition(to: .activated, message: detail)
            markVerified()
        case .disconnected(let reason):
            transition(to: .disconnected, message: reason)
            markVerified()
        case .unsupported(let reason):
            transition(to: .unsupported, message: reason)
            markVerified()
        case .failed(let reason):
            transition(to: .failed, message: reason)
        }
    }

    func reset() {
        persistence.removeAllActivationData()
        transition(to: .notActivated, message: "Activation data cleared.")
        lastVerifiedAt = nil
        persistence.setDate(nil, forKey: .activationLastVerified)
    }
}
