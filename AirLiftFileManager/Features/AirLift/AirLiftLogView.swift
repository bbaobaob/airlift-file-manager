import SwiftUI

struct LocalDevVPNSection: View {
    let state: VPNState
    let summary: String
    let background: String
    let isProbing: Bool
    let onRefresh: () -> Void

    var body: some View {
        Section {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(color)
                Text(state.displayTitle)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if isProbing {
                    ProgressView()
                } else {
                    Button {
                        onRefresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Re-probe tunnel")
                }
            }
            Text(summary)
                .font(.footnote)
                .foregroundStyle(.secondary)

            Text(background)
                .font(.caption2)
                .foregroundStyle(.tertiary)

            ForEach(AppConstants.LocalDevVPN.relatedProjects, id: \.self) { project in
                Label(project, systemImage: "link")
                    .font(.caption2)
            }
        } header: {
            Text("LocalDevVPN Status")
        } footer: {
            Text("Endpoint probed: 10.7.0.1:62078 (lockdown). A TCP connect is a real reachability check — no state is faked.")
        }
    }

    private var icon: String {
        switch state {
        case .connected: return "wifi.circle.fill"
        case .unreachable: return "wifi.slash"
        }
    }

    private var color: Color {
        switch state {
        case .connected: return .green
        case .unreachable: return .secondary
        }
    }
}

struct AirLiftLogView: View {
    @State private var entries: [AppLogger.Entry] = []
    @State private var filter: AppLogger.Category?

    var body: some View {
        List {
            Section {
                Picker("Category", selection: $filter) {
                    Text("All").tag(AppLogger.Category?.none)
                    ForEach(AppLogger.Category.allCases, id: \.self) { category in
                        Text(category.rawValue).tag(AppLogger.Category?.some(category))
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
            }
            Section {
                if filtered.isEmpty {
                    ContentUnavailableView("No log entries",
                                           systemImage: "doc.text.magnifyingglass")
                } else {
                    ForEach(filtered) { entry in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(entry.category.rawValue.uppercased())
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.tint)
                                Text(entry.level.rawValue)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(Formatters.date(entry.date))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Text(entry.message)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .navigationTitle("Technical Logs")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Clear") { AppLogger.shared.clear(); reload() }
            }
        }
        .onAppear(perform: reload)
    }

    private var filtered: [AppLogger.Entry] {
        guard let filter else { return entries }
        return entries.filter { $0.category == filter }
    }

    private func reload() {
        entries = AppLogger.shared.recentEntries().reversed()
    }
}
