import SwiftUI
import QuickLook
import UniformTypeIdentifiers

// MARK: - Directory picker for Copy / Move destinations

struct DirectoryPickerContext: Identifiable {
    enum Kind { case copy, move }
    let kind: Kind
    let title: String
    let urls: [URL]
    var id: String { kind == .copy ? "copy-\(urls.hashValue)" : "move-\(urls.hashValue)" }
}

struct DirectoryPickerView: View {
    @Environment(\.dismiss) private var dismiss
    let rootURL: URL
    let service: FileSystemService
    let title: String
    let onPick: (URL) -> Void

    @State private var currentURL: URL
    @State private var entries: [FileItem] = []
    @State private var loadError: String?

    init(rootURL: URL, service: FileSystemService, title: String,
         onPick: @escaping (URL) -> Void) {
        self.rootURL = rootURL
        self.service = service
        self.title = title
        self.onPick = onPick
        _currentURL = State(initialValue: rootURL)
    }

    var body: some View {
        NavigationStack {
            List {
                if currentURL != rootURL {
                    Button {
                        Task { await load(currentURL.deletingLastPathComponent()) }
                    } label: {
                        Label("Up one level", systemImage: "chevron.up")
                    }
                }
                ForEach(entries.filter(\.isDirectory)) { entry in
                    Button {
                        Task { await load(entry.url) }
                    } label: {
                        Label(entry.name, systemImage: "folder")
                    }
                }
                Section {
                    Button {
                        onPick(currentURL)
                        dismiss()
                    } label: {
                        Label("Move here" as String, systemImage: "checkmark.circle.fill")
                            .font(.headline)
                    }
                } footer: {
                    Text("Destination: \(currentURL.path)")
                        .font(.caption2.monospaced())
                }
                if let loadError {
                    Text(loadError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task { await load(currentURL) }
        }
    }

    private func load(_ url: URL) async {
        do {
            entries = try await service.listDirectory(at: url, includeHidden: false)
            currentURL = url
            loadError = nil
        } catch {
            loadError = ErrorHandler.userMessage(for: error)
        }
    }
}

// MARK: - Metadata sheet

struct FileMetadataSheet: View {
    @Environment(\.dismiss) private var dismiss
    let item: FileItem

    var body: some View {
        NavigationStack {
            List {
                Section("Item") {
                    LabeledRow(label: "Name", value: item.name)
                    LabeledRow(label: "Kind", value: item.typeLabel)
                    LabeledRow(label: "Size", value: item.isDirectory ? "—" : Formatters.fileSize(item.size))
                }
                Section("Dates") {
                    LabeledRow(label: "Modified", value: Formatters.date(item.modificationDate))
                    LabeledRow(label: "Created", value: Formatters.date(item.creationDate))
                }
                Section("Permissions") {
                    LabeledRow(label: "POSIX",
                               value: item.posixPermissions.map { String(format: "%o", $0) } ?? "—")
                    LabeledRow(label: "Hidden", value: item.isHidden ? "Yes" : "No")
                }
                Section("Path") {
                    Text(item.path)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
            .navigationTitle("Get Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Share & QuickLook

struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController,
                               previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}

/// Wrapper around fileImporter used by the Import File flow.
/// (Direct .fileImporter is attached in FilesView; kept here only for the
/// replace-flow importer coordination.)
