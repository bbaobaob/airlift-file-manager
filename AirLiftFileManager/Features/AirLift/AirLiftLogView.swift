import SwiftUI

struct LocalDevVPNSection: View {
    let state: VPNState
    let summary: String

    var body: some View {
        Section("LocalDevVPN Status") {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(color)
                Text(state.displayTitle)
                    .font(.subheadline.weight(.semibold))
            }
            Text(summary)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var icon: String {
        switch state {
        case .connected: return "wifi.circle.fill"
        case .notPartOfAirLift: return "wifi.slash"
        case .unavailable: return "exclamationmark.triangle"
        }
    }

    private var color: Color {
        switch state {
        case .connected: return .green
        case .notPartOfAirLift: return .secondary
        case .unavailable: return .orange
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
