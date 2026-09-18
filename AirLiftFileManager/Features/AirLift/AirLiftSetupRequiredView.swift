import SwiftUI

/// "AirLift Setup Required" screen. Shows three independent statuses with
/// the exact blocking reason. Pairing happens IN THIS APP (no separate
/// StikPair needed); a manual file import stays as the alternative for
/// records obtained elsewhere. Start AirLift stays disabled until
/// LocalDevVPN is Connected AND a valid Pairing File is imported AND
/// preflight reaches Ready to Start.
struct AirLiftSetupRequiredView: View {
    @ObservedObject var guardVM: AirLiftLaunchGuard
    let onDismiss: () -> Void

    @State private var showPairingImporter = false
    @State private var showInAppPairing = false

    var body: some View {
        NavigationStack {
            List {
                statusSection
                if let reason = guardVM.lastFailureReason {
                    Section {
                        Label(reason, systemImage: "exclamationmark.shield.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    } header: {
                        Text("Blocking Reason")
                    }
                }
                pairingSection
                actionsSection
                footerSection
            }
            .navigationTitle("AirLift Setup Required")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Later") { onDismiss() }
                        .accessibilityLabel("Continue in sandbox-only mode")
                }
            }
            .fileImporter(isPresented: $showPairingImporter,
                          allowedContentTypes: PairingFileSupport.supportedContentTypes,
                          allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else {
                        guardVM.pairingStatusMessage = "No file was selected."
                        return
                    }
                    if urls.count > 1 {
                        AppLogger.pairing.info(
                            "Multiple files selected (\(urls.count)); using the first one",
                            event: "pairing.import")
                    }
                    Task {
                        await guardVM.importPairing(from: url)
                        await guardVM.recheckConnection()
                    }
                case .failure(let error):
                    // Never swallow picker errors: the "tap does nothing"
                    // complaint is undiagnosable otherwise.
                    guardVM.pairingStatusMessage =
                        "Picker error: \(error.localizedDescription). " +
                        "Tap a .plist or .mobiledevicepairing file under Browse › On My iPhone."
                    AppLogger.pairing.error(
                        "Document picker failed: \(error.localizedDescription)",
                        event: "pairing.import")
                }
            }
            .sheet(isPresented: $showInAppPairing) {
                InAppPairingView(model: InAppPairingViewModel(
                    pairingStore: guardVM.pairingStore)) {
                        Task { await guardVM.recheckConnection() }
                    }
            }
            .task { await guardVM.recheckConnection() }
            .onChange(of: guardVM.launchState) { _, newState in
                // Setup finished its job once AirLift is Ready to Start (or beyond).
                if newState == .readyToStart || newState == .running {
                    onDismiss()
                }
            }
        }
    }

    // MARK: - Sections

    private var statusSection: some View {
        Section("Status") {
            statusRow(icon: "wifi.circle.fill",
                      title: "LocalDevVPN",
                      value: guardVM.vpnStatus.rawValue,
                      ok: guardVM.vpnStatus == .connected,
                      checking: guardVM.vpnStatus == .checking)
            statusRow(icon: "key.horizontal.fill",
                      title: "Pairing File",
                      value: guardVM.pairingStatus.rawValue,
                      ok: guardVM.pairingStatus == .imported,
                      checking: false)
            statusRow(icon: "airplane.departure",
                      title: "AirLift",
                      value: guardVM.launchState.rawValue,
                      ok: guardVM.launchState == .readyToStart || guardVM.launchState == .running,
                      checking: guardVM.launchState == .starting)
        }
    }

    private func statusRow(icon: String, title: String, value: String,
                           ok: Bool, checking: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(ok ? Color.green : (checking ? Color.blue : Color.orange))
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(value)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if checking { ProgressView() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value)")
    }

    private var pairingSection: some View {
        Section {
            Text(guardVM.pairingStatusMessage)
                .font(.footnote)
            Button {
                showInAppPairing = true
            } label: {
                Label("Pair This iPhone Here", systemImage: "key.horizontal.fill")
            }
            .font(.headline)
            Button {
                showPairingImporter = true
            } label: {
                Label(guardVM.pairingStore.hasRecord
                      ? "Replace Pairing File" : "Import Pairing File",
                      systemImage: "key.horizontal")
            }
            .font(.footnote)
            if guardVM.pairingStore.hasRecord {
                Button(role: .destructive) {
                    guardVM.removePairing()
                } label: {
                    Label("Remove Pairing File", systemImage: "key.slash")
                }
                .font(.footnote)
            }
        } header: {
            Text("Pairing")
        } footer: {
            Text("Pairing runs the real on-device ceremony (advertise, PIN, SRP) inside this app — no separate StikPair needed. Import stays for records obtained elsewhere (e.g. iloader). Records live in the Keychain and are never logged.")
        }
    }

    private var actionsSection: some View {
        Section {
            Button {
                Task { await guardVM.recheckConnection() }
            } label: {
                HStack {
                    Label("Recheck Connection", systemImage: "arrow.clockwise.circle")
                    if guardVM.isChecking { Spacer(); ProgressView() }
                }
            }
            .disabled(guardVM.isChecking)

            Button {
                Task { await guardVM.startAirLift() }
            } label: {
                HStack {
                    Label(startButtonTitle, systemImage: "bolt.horizontal.circle.fill")
                    if guardVM.launchState == .starting { Spacer(); ProgressView() }
                }
            }
            .disabled(!guardVM.canStartAirLift
                      || guardVM.isChecking
                      || guardVM.launchState == .starting)
            if !guardVM.canStartAirLift && guardVM.launchState != .failed {
                Text("Start AirLift is disabled until LocalDevVPN is Connected and a valid Pairing File is imported.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("AirLift")
        }
    }

    private var startButtonTitle: String {
        switch guardVM.launchState {
        case .starting: return "Starting…"
        case .running: return "Running"
        case .failed: return "Retry Start AirLift"
        default: return "Start AirLift"
        }
    }

    private var footerSection: some View {
        Section {
            Button {
                onDismiss()
            } label: {
                Label("Continue in Sandbox-Only Mode", systemImage: "folder")
            }
            Text("The Files tab always works on this app's real sandbox. A tunnel or a pairing record alone is NOT proof that AirLift is active — AirLift launches only through the guarded preflight.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    AirLiftSetupRequiredView(guardVM: AirLiftLaunchGuard(), onDismiss: {})
}
