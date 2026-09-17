import SwiftUI

struct ActivationView: View {
    @StateObject private var vm = ActivationViewModel()

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Text("State: \(vm.state.displayName)")
                    .font(.headline)
                    .accessibilityIdentifier("activationState")
                Text("On-device uses only: NotActivated / TetherRequired / VerificationPending / VerifiedViaTether / Unsupported.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                TextEditor(text: $vm.jsonText)
                    .border(Color.secondary.opacity(0.3))
                    .frame(minHeight: 140)
                    .padding(.horizontal)
                    .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                Text(vm.info)
                    .font(.footnote)
                    .padding(.horizontal)
                HStack {
                    Button("Tether Required") { vm.markTetherRequired() }
                        .buttonStyle(.bordered)
                    Button("Verify") { vm.verifyPasted() }
                        .buttonStyle(.borderedProminent)
                    Button("Reset") { vm.reset() }
                        .buttonStyle(.bordered)
                }
                Spacer()
                Text("Companion Viewer + Sandbox Demo. No on-device exploit. Activation requires Mac TetherResult JSON.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding()
            }
            .navigationTitle("AirLift")
        }
    }
}

#Preview { ActivationView() }
