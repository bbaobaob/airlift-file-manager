import SwiftUI

/// AirLift tab: launch gate status + AirLift Launch + Setup only. Everything
/// else (self-test, Books, pairing/import, VPN status, lockdown,
/// access diagnostics) was removed — Setup covers VPN/pairing, logs stay
/// behind the toolbar button.
struct AirLiftView: View {
    @EnvironmentObject private var launchGuard: AirLiftLaunchGuard
    @StateObject private var model = AirLiftViewModel()
    @State private var showingLogs = false
    @State private var showingSetup = false

    var body: some View {
        NavigationStack {
            List {
                connectionSection
            }
            .navigationTitle("AirLift")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingLogs = true
                    } label: {
                        Image(systemName: "doc.text.magnifyingglass")
                    }
                    .accessibilityLabel("Technical logs")
                }
            }
            .sheet(isPresented: $showingLogs) {
                NavigationStack { LogViewerView() }
            }
            .sheet(isPresented: $showingSetup) {
                AirLiftSetupRequiredView(guardVM: launchGuard) { showingSetup = false }
            }
            .task {
                model.refreshAccessReports()
                await model.probeTunnel()
            }
            .refreshable {
                model.refreshAccessReports()
                await model.probeTunnel()
            }
        }
    }

    private var connectionSection: some View {
        Section {
            launchStatusRow(title: "LocalDevVPN",
                            value: launchGuard.vpnStatus.rawValue,
                            ok: launchGuard.vpnStatus == .connected)
            launchStatusRow(title: "Pairing File",
                            value: launchGuard.pairingStatus.rawValue,
                            ok: launchGuard.pairingStatus == .imported)
            launchStatusRow(title: "AirLift",
                            value: launchGuard.launchState.rawValue,
                            ok: launchGuard.launchState == .readyToStart
                                || launchGuard.launchState == .running)
            if let reason = launchGuard.lastFailureReason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button {
                    Task { await launchGuard.startAirLift() }
                } label: {
                    Label(launchGuard.launchState == .failed ? "Retry Start AirLift" : "Start AirLift",
                          systemImage: "bolt.horizontal.circle.fill")
                }
                .disabled(!launchGuard.canStartAirLift
                          || launchGuard.isChecking
                          || launchGuard.launchState == .starting)
                if launchGuard.launchState == .starting {
                    Spacer()
                    ProgressView()
                }
            }
            Button("Recheck Connection") {
                Task { await launchGuard.recheckConnection() }
            }
            .disabled(launchGuard.isChecking)
            Button("AirLift Setup") { showingSetup = true }
                .font(.footnote.weight(.medium))
        } header: {
            Text("AirLift Launch")
        } footer: {
            Text("AirLift operates only with LocalDevVPN Connected and a valid Pairing File. Start runs the real on-device chain (pair-verify → RSD → AFC self-test); scope is AFC file access.")
        }
    }

    private func launchStatusRow(title: String, value: String, ok: Bool) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(ok ? Color.green : Color.orange)
            Text(title)
            Spacer()
            Text(value)
                .font(.footnote.weight(.medium))
                .foregroundStyle(ok ? .green : .orange)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value)")
    }
}

struct LabeledRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}

#Preview {
    AirLiftView()
        .environmentObject(AirLiftLaunchGuard())
}
