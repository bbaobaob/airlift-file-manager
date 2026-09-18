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

/// Professional log viewer: real-time tail, search, level/category filters,
/// row selection, copy/share/clear/export (TXT + JSON), pause/resume,
/// bounded memory (AppLogger ring buffer), full error context.
struct LogViewerView: View {
    @State private var entries: [AppLogger.Entry] = []
    @State private var searchText = ""
    @State private var selectedLevels: Set<AppLogger.Entry.Level> = []
    @State private var selectedCategories: Set<AppLogger.Category> = []
    @State private var selectionActive = false
    @State private var selectedIDs: Set<UUID> = []
    @State private var isPaused = false
    @State private var autoScroll = true
    @State private var shareItem: ShareFileItem?

    private var filtered: [AppLogger.Entry] {
        AppLogger.filter(entries: entries,
                         searchText: searchText,
                         levels: selectedLevels,
                         categories: selectedCategories)
    }

    var body: some View {
        List(selection: selectionActive ? $selectedIDs : nil) {
            Section {
                summaryRow
                    .listRowBackground(Color.clear)
            }
            Section {
                if filtered.isEmpty {
                    ContentUnavailableView("No log entries",
                                           systemImage: "doc.text.magnifyingglass")
                } else {
                    ForEach(filtered) { entry in
                        logRow(entry)
                    }
                }
            }
        }
        .listStyle(.plain)
        .searchable(text: $searchText, prompt: "Search messages, subsystem, event")
        .navigationTitle("Technical Logs")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .sheet(item: $shareItem) { item in
            ActivityShareSheet(items: [item.url])
        }
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: AppLogger.appLogDidAppend)) { _ in
            guard !isPaused else { return }
            reload()
        }
    }

    private var summaryRow: some View {
        HStack {
            Text("\(filtered.count) of \(AppLogger.shared.entryCount) entries")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()
            if isPaused {
                Label("Paused", systemImage: "pause.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func logRow(_ entry: AppLogger.Entry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(entry.category.title.uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tint)
                Text(entry.level.title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(levelColor(entry.level))
                if let event = entry.event {
                    Text(event)
                        .font(.caption2.italic())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(Formatters.time(entry.date))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Text(entry.message)
                .font(.caption.monospaced())
                .textSelection(.enabled)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard selectionActive else { return }
            if selectedIDs.contains(entry.id) {
                selectedIDs.remove(entry.id)
            } else {
                selectedIDs.insert(entry.id)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.level.title) log from \(entry.category.title)")
    }

    private func levelColor(_ level: AppLogger.Entry.Level) -> Color {
        switch level {
        case .debug: return .secondary
        case .info: return .blue
        case .warning: return .orange
        case .error: return .red
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Toggle(isOn: $autoScroll) { Label("Auto-scroll", systemImage: "arrow.down.to.line") }
                Toggle(isOn: $isPaused) { Label(isPaused ? "Resume" : "Pause", systemImage: isPaused ? "play.circle" : "pause.circle") }
                Divider()
                Menu("Levels") {
                    ForEach(AppLogger.Entry.Level.allCases, id: \.self) { level in
                        Button {
                            toggle(level, in: &selectedLevels)
                        } label: {
                            Label(level.title,
                                  systemImage: selectedLevels.contains(level) ? "checkmark" : "circle")
                        }
                    }
                }
                Menu("Categories") {
                    ForEach(AppLogger.Category.allCases, id: \.self) { category in
                        Button {
                            toggle(category, in: &selectedCategories)
                        } label: {
                            Label(category.title,
                                  systemImage: selectedCategories.contains(category) ? "checkmark" : "circle")
                        }
                    }
                }
                Button(role: .destructive) {
                    AppLogger.shared.clear()
                    reload()
                } label: {
                    Label("Clear Logs", systemImage: "trash")
                }
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
            }
            .accessibilityLabel("Log filters and actions")
        }

        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    selectionActive.toggle()
                    if !selectionActive { selectedIDs.removeAll() }
                } label: {
                    Label(selectionActive ? "Cancel Selection" : "Select Entries",
                          systemImage: selectionActive ? "xmark.circle" : "checkmark.circle")
                }
                Button {
                    selectedIDs = Set(filtered.map(\.id))
                } label: {
                    Label("Select All", systemImage: "checkmark.circle.fill")
                }
                .disabled(filtered.isEmpty)
                Button {
                    copyToClipboard(entries: selectedEntries)
                } label: {
                    Label("Copy Selected", systemImage: "doc.on.doc")
                }
                .disabled(selectedEntries.isEmpty)
                Button {
                    copyToClipboard(entries: filtered)
                } label: {
                    Label("Copy All (filtered)", systemImage: "doc.on.doc.fill")
                }
                .disabled(filtered.isEmpty)
                Divider()
                Button {
                    exportAs(.txt)
                } label: {
                    Label("Export as TXT", systemImage: "square.and.arrow.up")
                }
                Button {
                    exportAs(.json)
                } label: {
                    Label("Export as JSON", systemImage: "curlybraces.square")
                }
                Button {
                    shareText(AppLogger.exportTXT(filtered))
                } label: {
                    Label("Share Logs", systemImage: "square.and.arrow.up.fill")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("Log export and selection actions")
        }
    }

    private var selectedEntries: [AppLogger.Entry] {
        filtered.filter { selectedIDs.contains($0.id) }
    }

    private func toggle<T: Hashable>(_ value: T, in set: inout Set<T>) {
        if set.contains(value) { set.remove(value) } else { set.insert(value) }
    }

    private func copyToClipboard(entries: [AppLogger.Entry]) {
        UIPasteboard.general.string = AppLogger.exportTXT(entries)
    }

    private func shareText(_ text: String) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("airlift-logs-\(Int(Date().timeIntervalSince1970)).txt")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            shareItem = ShareFileItem(url: url)
        } catch {
            AppLogger.app.error("Log share failed: \(error.localizedDescription)")
        }
    }

    private enum ExportFormat {
        case txt, json
    }

    private func exportAs(_ format: ExportFormat) {
        let base = "airlift-logs-\(Int(Date().timeIntervalSince1970))"
        switch format {
        case .txt:
            shareText(AppLogger.exportTXT(filtered))
        case .json:
            guard let data = AppLogger.exportJSON(filtered) else {
                AppLogger.app.error("Log JSON export failed to encode")
                return
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(base + ".json")
            do {
                try data.write(to: url, options: .atomic)
                shareItem = ShareFileItem(url: url)
            } catch {
                AppLogger.app.error("Log JSON write failed: \(error.localizedDescription)")
            }
        }
    }

    private func reload() {
        entries = AppLogger.shared.recentEntries()
    }
}

struct ShareFileItem: Identifiable {
    let url: URL
    var id: URL { url }
}
