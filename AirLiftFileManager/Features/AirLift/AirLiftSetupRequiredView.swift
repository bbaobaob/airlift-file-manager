import SwiftUI

/// "AirLift Setup Required" screen. Shown whenever the launch requirements
/// are not met. Shows three independent statuses (LocalDevVPN / Pairing File /
/// AirLift) with the exact blocking reason, and every action the user needs.
/// Start AirLift stays disabled until LocalDevVPN is Connected AND a valid
/// Pairing File is imported AND preflight reaches Ready to Start.
struct AirLiftSetupRequiredView: View {
    @ObservedObject var guardVM: AirLiftLaunchGuard
    let onDismiss: () -> Void

    @State private var showPairingImporter = false
    @State private var showVPNHelp = false

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
                vpnSection
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

    private var vpnSection: some View {
        Section {
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Label("Open iOS Settings (VPN)", systemImage: "gear")
            }
            Button {
                showVPNHelp = true
            } label: {
                Label("How to enable LocalDevVPN", systemImage: "questionmark.circle")
            }
            if showVPNHelp {
                VStack(alignment: .leading, spacing: 6) {
                    Text("1. Install LocalDevVPN (or SideStore StosVPN).")
                    Text("2. Open it and connect the tunnel (device IP 10.7.0.0, fake IP 10.7.0.1).")
                    Text("3. Keep Wi-Fi enabled while the tunnel is active.")
                    Text("4. Return here and tap Recheck Connection.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        } header: {
            Text("1 · LocalDevVPN")
        } footer: {
            Text("The tunnel maps 10.7.0.1 back to this device's lockdown (port 62078). Without it AirLift is Locked.")
        }
    }

    private var pairingSection: some View {
        Section {
            Text(guardVM.pairingStatusMessage)
                .font(.footnote)
            Button {
                showPairingImporter = true
            } label: {
                Label(guardVM.pairingStore.hasRecord
                      ? "Replace Pairing File" : "Import Pairing File",
                      systemImage: "key.horizontal")
            }
            if guardVM.pairingStore.hasRecord {
                Button(role: .destructive) {
                    guardVM.removePairing()
                } label: {
                    Label("Remove Pairing File", systemImage: "key.slash")
                }
            }
        } header: {
            Text("2 · Pairing File")
        } footer: {
            Text("Import here with the button above, or share the file from StikPair and choose \"Copy to AirLift File Manager\". Pair on-device: Settings › Privacy & Security › Developer Mode › Pair with StikPair. The record is stored in the Keychain and never logged. Expiry cannot be detected before trusted sessions are implemented — if you re-paired in StikPair, import the new file.")
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
            Text("3 · AirLift")
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
            Text("The Files tab always works on this app's real sandbox. Importing a Pairing File or connecting the tunnel is NOT proof that AirLift is active — AirLift launches only through the guarded preflight, and this build reports 'Transport unavailable' honestly instead of faking a Running state.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    AirLiftSetupRequiredView(guardVM: AirLiftLaunchGuard(), onDismiss: {})
}
