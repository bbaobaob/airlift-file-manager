import SwiftUI

/// In-app pairing, StikPair-style but built in: advertise this iPhone as a
/// pairable host, show the 6-digit PIN, wait for the user to enter it in
/// Settings › Developer Mode › Pair with AirLift, then save the fresh
/// pairing record. No separate StikPair app required, no mock states.
@MainActor
final class InAppPairingViewModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case starting
        case waitingForDevice
        case pinShown(String)
        case verifying
        case succeeded(deviceName: String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle

    private let pairingStore: any PairingStoring
    private let hostStore: HostIdentityStore
    private var runTask: Task<Void, Never>?

    init(pairingStore: any PairingStoring = KeychainPairingStore(),
         hostStore: HostIdentityStore = HostIdentityStore()) {
        self.pairingStore = pairingStore
        self.hostStore = hostStore
    }

    var isRunning: Bool {
        switch phase {
        case .starting, .waitingForDevice, .pinShown, .verifying:
            return true
        case .idle, .succeeded, .failed:
            return false
        }
    }

    func start() {
        guard !isRunning else { return }
        phase = .starting
        runTask = Task { [weak self] in
            await self?.runPairing()
        }
    }

    func cancel() {
        runTask?.cancel()
        runTask = nil
        if isRunning {
            phase = .failed("Cancelled.")
        }
    }

    private func runPairing() async {
        // Host identity (stable across runs so paired devices recognize us).
        let identity: PairingHost.HostIdentity
        if let stored = hostStore.load() {
            identity = stored
        } else {
            let fresh = PairingHost.HostIdentity.generate()
            guard hostStore.save(fresh) else {
                phase = .failed("Could not store the pairing-host identity in the Keychain.")
                return
            }
            identity = fresh
        }

        let advertiser = PairingAdvertiser()
        do {
            phase = .waitingForDevice
            AppLogger.pairing.info("In-app pairing started", event: "pairing.host")
            let (connection, port) = try await advertiser.advertiseAndAccept(
                identity: identity, timeout: 180)
            AppLogger.pairing.info("Device connected for pairing (port \(port))",
                                   event: "pairing.host")
            let stream = TCPStream(wrapping: connection, queue: .main)
            var acceptor = PairingAcceptor(stream: stream, identity: identity,
                                           pairingStore: pairingStore) { [weak self] pin in
                await MainActor.run { [weak self] in
                    self?.phase = .pinShown(pin)
                }
                AppLogger.pairing.info("PIN displayed for device entry",
                                       event: "pairing.host")
            }
            phase = .verifying
            let peer = try await acceptor.accept()
            advertiser.stop()
            AppLogger.pairing.info("In-app pairing complete", event: "pairing.host")
            phase = .succeeded(deviceName: peer.name.isEmpty ? "iPhone" : peer.name)
        } catch is CancellationError {
            advertiser.stop()
            phase = .failed("Cancelled.")
        } catch {
            advertiser.stop()
            AppLogger.pairing.error("In-app pairing failed: \(error)",
                                    event: "pairing.host")
            phase = .failed(friendlyError(error))
        }
    }

    private func friendlyError(_ error: Error) -> String {
        if let pairError = error as? PairingHost.PairError {
            switch pairError {
            case .timeout:
                return "Timed out waiting for the device. Open Settings › Developer Mode › Pair with AirLift and try again."
            case .srpFailed(let reason):
                return reason
            case .protocolError(let reason):
                return "Pairing protocol error: \(reason)"
            case .listenerFailed(let reason):
                return "Could not listen for pairing: \(reason). Allow Local Network access in Settings."
            case .publishFailed:
                return "Could not advertise pairing. Allow Local Network access in Settings."
            case .cancelled:
                return "Cancelled."
            }
        }
        if let advertiseError = error as? PairingAdvertiser.AdvertiseError {
            switch advertiseError {
            case .timeout:
                return "Timed out waiting for the device. Open Settings › Developer Mode › Pair with AirLift and try again."
            case .listenerFailed, .publishFailed:
                return "Networking unavailable. Allow Local Network access in Settings and retry."
            case .cancelled:
                return "Cancelled."
            }
        }
        return error.localizedDescription
    }
}

struct InAppPairingView: View {
    @ObservedObject var model: InAppPairingViewModel
    let onPaired: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    switch model.phase {
                    case .idle:
                        Text("Pair this iPhone without leaving the app. AirLift advertises itself, you confirm with a PIN in Settings, and the pairing record is saved to the Keychain.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    case .starting:
                        pairingProgressRow("Starting pairing…")
                    case .waitingForDevice:
                        pairingProgressRow("Waiting for the device…")
                        Text("On this iPhone open Settings › Privacy & Security › Developer Mode › Pair with AirLift.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    case .pinShown(let pin):
                        Text("Enter this PIN on the device:")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text(pin.map(String.init).joined(separator: " "))
                            .font(.system(size: 44, weight: .bold, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .center)
                            .textSelection(.enabled)
                            .accessibilityLabel("Pairing PIN \(pin)")
                        pairingProgressRow("Waiting for PIN entry…")
                    case .verifying:
                        pairingProgressRow("Verifying…")
                    case .succeeded(let deviceName):
                        Label("Paired with \(deviceName). Pairing record saved.",
                              systemImage: "checkmark.seal.fill")
                            .font(.headline)
                            .foregroundStyle(.green)
                    case .failed(let reason):
                        Label(reason, systemImage: "xmark.octagon.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Section {
                    if model.isRunning {
                        Button("Cancel", role: .cancel) { model.cancel() }
                    } else {
                        Button {
                            model.start()
                        } label: {
                            Label(pairButtonTitle, systemImage: "key.horizontal.fill")
                        }
                        if case .succeeded = model.phase {
                            Button("Done") {
                                onPaired()
                                dismiss()
                            }
                            .font(.headline)
                        }
                    }
                } footer: {
                    Text("The same on-device ceremony as StikPair (PIN + SRP), implemented here from the published protocol. Nothing is simulated.")
                }
            }
            .navigationTitle("Pair This iPhone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private var pairButtonTitle: String {
        if case .failed = model.phase { return "Retry Pairing" }
        return "Pair This iPhone"
    }

    private func pairingProgressRow(_ text: String) -> some View {
        HStack {
            ProgressView()
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
