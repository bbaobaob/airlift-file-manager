import SwiftUI

/// On-device RSD+AFC self-test runner UI. The test is enabled ONLY when the
/// launch guard is satisfied (LocalDevVPN Connected + valid Pairing File +
/// preflight Ready) — the same gates as Start AirLift. Results are the real
/// chain outcome (write/read/remove through RSD+AFC); nothing is simulated.
@MainActor
final class SelfTestViewModel: ObservableObject {
    enum State: Equatable {
        case idle
        case running
        case passed(String)
        case failed(step: String, reason: String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lines: [String] = []
    private var runTask: Task<Void, Never>?

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    func run() {
        guard runTask == nil else { return }
        state = .running
        lines = []
        runTask = Task { [weak self] in
            let chain = OnDeviceChain(log: { line in
                Task { @MainActor [weak self] in
                    self?.lines.append(line)
                }
            })
            let outcome = await chain.runSelfTest()
            await MainActor.run { [weak self] in
                guard let self else { return }
                switch outcome {
                case .passed(let detail):
                    self.state = .passed(detail)
                case .failed(let step, let reason):
                    self.state = .failed(step: step, reason: reason)
                }
                self.runTask = nil
            }
        }
    }

    func cancel() {
        runTask?.cancel()
        runTask = nil
        if isRunning {
            lines.append("Cancelled by user.")
            state = .idle
        }
    }

    func clear() {
        guard !isRunning else { return }
        state = .idle
        lines = []
    }
}

struct SelfTestView: View {
    @ObservedObject var guardVM: AirLiftLaunchGuard
    @StateObject private var model = SelfTestViewModel()

    var body: some View {
        Section {
            if !model.lines.isEmpty {
                ForEach(model.lines.indices, id: \.self) { index in
                    Text(model.lines[index])
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            switch model.state {
            case .idle:
                Text("Runs the real chain: pair-verify → tunnel → RSD → AFC write/read/remove of a marker file.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .running:
                HStack {
                    ProgressView()
                    Text("Running on-device self-test…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            case .passed(let detail):
                Label("SELF-TEST PASSED — \(detail)",
                      systemImage: "checkmark.seal.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.green)
                    .fixedSize(horizontal: false, vertical: true)
            case .failed(let step, let reason):
                Label("FAILED at \(step): \(reason)",
                      systemImage: "xmark.octagon.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button {
                    model.run()
                } label: {
                    Label(runButtonTitle, systemImage: "bolt.horizontal.circle.fill")
                }
                .disabled(!guardVM.canStartAirLift || model.isRunning)
                if model.isRunning {
                    Button("Cancel", role: .cancel) { model.cancel() }
                        .font(.footnote)
                } else if !model.lines.isEmpty {
                    Button("Clear") { model.clear() }
                        .font(.footnote)
                }
            }
            if !guardVM.canStartAirLift {
                Text("Requires LocalDevVPN Connected and a valid Pairing File (same gates as Start AirLift).")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("On-Device Self-Test (RSD + AFC)")
        } footer: {
            Text("Proves the real transport: remote-pairing handshake, RSD service discovery and AFC file write/read/remove through the LocalDevVPN tunnel. Writes only a temporary marker file in the AFC scope and removes it afterwards.")
        }
    }

    private var runButtonTitle: String {
        if case .failed = model.state { return "Retry Self-Test" }
        return "Run On-Device Self-Test"
    }
}
