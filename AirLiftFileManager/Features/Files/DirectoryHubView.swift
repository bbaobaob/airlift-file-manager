import SwiftUI

/// Root of the Files tab: shows real probed locations. Tapping an accessible
/// location opens the existing file browser rooted there.
struct DirectoryHubView: View {
    let ops: FileOperationManager
    @StateObject private var model = DirectoryHubViewModel()

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Files")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { Task { await model.refresh() } } label: {
                            if model.isProbing {
                                ProgressView()
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                        .accessibilityLabel("Refresh locations")
                    }
                }
                .task { await model.refresh() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.locations.isEmpty && model.isProbing {
            ProgressView("Probing locations…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                introSection
                ForEach(model.locations) { location in
                    locationRow(location)
                }
                airLiftSection
                if let probed = model.lastProbedAt {
                    Section {
                        Text("Last probe: \(Formatters.date(probed))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    private var introSection: some View {
        Section {
            Text("Each location below was probed from this device. Only paths your sandbox can independently reach will open; restricted paths show their verified status instead of pretending.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var airLiftSection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: "externaldrive.badge.icloud")
                    .font(.title3)
                    .foregroundStyle(Color.purple)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text("AirLift scope (paired Mac)")
                        .font(.subheadline.weight(.medium))
                    Text("AirLift executes on a paired Mac (AirTrafficHost.framework). Browsing this scope from on-device needs a Mac-host relay that does not exist yet, so no content is shown here.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Badge(level: .requiresExternalComponent)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("AirLift scope requires a paired Mac relay, not available")
        } header: {
            Text("AirLift-Backed Access")
        }
    }

    private func locationRow(_ location: FilesystemLocation) -> some View {
        Group {
            if location.access.canBrowse {
                NavigationLink {
                    FilesView(
                        service: scopedService(for: location),
                        operations: ops,
                        rootURL: URL(fileURLWithPath: location.path, isDirectory: true),
                        locationTitle: location.title)
                } label: {
                    locationBody(location)
                }
            } else {
                locationBody(location)
            }
        }
    }

    private func scopedService(for location: FilesystemLocation) -> FileSystemService {
        // The sandbox backend already enforces in-scope checks; give it the
        // probed path as the root scope. Access levels from live probing.
        // For restricted/non-browsable paths we never build a service.
        let root = URL(fileURLWithPath: location.path, isDirectory: true)
        let caps: FileSystemCapabilities = location.access == .readOnly ? .readOnly : .fullSandbox
        return SandboxFileSystemService(scopeRoots: [root], capabilities: caps)
    }

    private func locationBody(_ location: FilesystemLocation) -> some View {
        HStack(spacing: 12) {
            Image(systemName: location.access.canBrowse ? "folder.fill" : "lock.shield")
                .font(.title3)
                .foregroundStyle(badgeColor(location.access))
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(location.title)
                    .font(.subheadline.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(location.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Badge(level: location.access)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(location.title), \(location.access.rawValue)\(location.access.canBrowse ? ", tap to browse" : "")")
    }

    private func badgeColor(_ level: AccessLevel) -> Color {
        switch level {
        case .accessible: return .green
        case .readOnly: return .blue
        case .restricted: return .orange
        case .notFound: return .gray
        case .notTested: return .gray
        case .connectionRequired: return .purple
        case .unsupported, .requiresExternalComponent: return .secondary
        }
    }
}

struct Badge: View {
    let level: AccessLevel
    var body: some View {
        Text(level.rawValue)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
    private var color: Color {
        switch level {
        case .accessible: return .green
        case .readOnly: return .blue
        case .restricted: return .orange
        case .notFound, .notTested: return .gray
        case .connectionRequired: return .purple
        case .unsupported, .requiresExternalComponent: return .secondary
        }
    }
}
