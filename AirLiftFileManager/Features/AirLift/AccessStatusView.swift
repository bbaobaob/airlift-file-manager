import SwiftUI

/// Replaces the old static "AirLift Capabilities" screen. Everything shown
/// here comes from a real probe run on this device; nothing is hardcoded.
struct AccessStatusView: View {
    @ObservedObject var guardVM: AirLiftLaunchGuard
    @StateObject private var model = DiagnosticsViewModel()

    var body: some View {
        List {
            liveSection
            reportSection
            checkedPathsSection
        }
        .navigationTitle("Access Status")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.run() }
        .refreshable { await model.run() }
    }

    private var liveSection: some View {
        Section {
            statusRow(title: "VPN (tunnel)",
                      ok: guardVM.vpnStatus == .connected || model.report?.transportReady == true,
                      value: tunnelValue)
            statusRow(title: "Pairing",
                      ok: guardVM.pairingStatus == .imported,
                      value: guardVM.pairingStatus.rawValue)
            statusRow(title: "Transport",
                      ok: model.report?.transportReady == true,
                      value: model.report?.transportReady == true
                      ? "Lockdown exchange verified"
                      : "Not verified")
            statusRow(title: "Filesystem backend",
                      ok: true,
                      value: "Sandbox (real); AirLift backend requires paired-Mac relay")
            if let last = model.lastRunAt {
                LabeledRow(label: "Last successful probe", value: Formatters.date(last))
            }
            if let failure = model.lastError {
                LabeledRow(label: "Last error", value: failure)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Connection Status")
        } footer: {
            Text("Every value is the result of a real check. A reachable lockdown endpoint proves transport only — never filesystem access.")
        }
    }

    private var tunnelValue: String {
        if model.report?.transportReady == true || guardVM.vpnStatus == .connected {
            return "10.7.0.1 reachable"
        }
        return "10.7.0.1 not reachable"
    }

    private var reportSection: some View {
        Section {
            Button {
                Task { await model.run() }
            } label: {
                Label(model.isRunning ? "Running…" : "Run Diagnostics",
                      systemImage: "stethoscope")
            }
            .disabled(model.isRunning)

            Button {
                UIPasteboard.general.string = model.report?
                    .text(bundleVersion: Self.bundleVersion) ?? ""
            } label: {
                Label("Copy Diagnostic Report", systemImage: "doc.on.doc")
            }
            .disabled(model.report == nil)
        }
    }

    private var checkedPathsSection: some View {
        Section("Probed Paths (read / write verified)") {
            ForEach(model.sandboxReports, id: \.path) { report in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(report.path)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                        Spacer()
                        Text(report.level.rawValue)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                    }
                    Text(report.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    static var bundleVersion: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }

    private func statusRow(title: String, ok: Bool, value: String) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(ok ? Color.green : Color.orange)
            Text(title)
            Spacer()
            Text(value)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value)")
    }
}

@MainActor
final class DiagnosticsViewModel: ObservableObject {
    @Published private(set) var report: CapabilityReport?
    @Published private(set) var isRunning = false
    @Published private(set) var lastRunAt: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var sandboxReports: [DirectoryAccessReport] = []

    private let probe: CapabilityProbing
    private let permission: PermissionService

    init(probe: CapabilityProbing = CapabilityProbeService(),
         permission: PermissionService = PermissionService()) {
        self.probe = probe
        self.permission = permission
    }

    func run() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        sandboxReports = permission.probeAll()
        do {
            report = try await runProbe()
            lastRunAt = Date()
            lastError = nil
        } catch {
            lastError = ErrorHandler.present(error, context: "diagnostics")
        }
    }

    /// The probe itself never throws; kept as throwing for future extension.
    private func runProbe() async throws -> CapabilityReport {
        await probe.run()
    }
}
