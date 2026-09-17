import SwiftUI
import UniformTypeIdentifiers

struct FilesView: View {
    @StateObject private var model: FilesViewModel

    // Sheets & flows
    @State private var showNewFolderAlert = false
    @State private var newFolderName = ""
    @State private var renameTarget: URL?
    @State private var renameText = ""
    @State private var infoItem: FileItem?
    @State private var shareURL: URL?
    @State private var previewURL: URL?
    @State private var directoryPicker: DirectoryPickerContext?
    @State private var importPicker = false
    @State private var replaceTarget: URL?
    @State private var deleteConfirmation: [URL]?
    @State private var zipMetadataFile: URL?

    init(service: FileSystemService,
         operations: FileOperationManager) {
        _model = StateObject(wrappedValue: FilesViewModel(service: service,
                                                          operations: operations))
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(model.directoryTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(content: toolbarItems)
                .overlay(alignment: .bottom) {
                    if model.selection.isActive {
                        selectionStatusBar
                    }
                }
        }
        .task { await model.refresh() }
        .alert("New Folder", isPresented: $showNewFolderAlert) {
            TextField("Folder name", text: $newFolderName)
            Button("Create") { Task { await model.createFolder(named: newFolderName); newFolderName = "" } }
            Button("Cancel", role: .cancel) { newFolderName = "" }
        } message: {
            Text("Enter a name for the new folder.")
        }
        .alert("Rename", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } })) {
            TextField("New name", text: $renameText)
            Button("Rename") {
                if let target = renameTarget {
                    Task { await model.rename(item: target, to: renameText) }
                }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
        .alert("Delete",
               isPresented: Binding(get: { deleteConfirmation != nil },
                                    set: { if !$0 { deleteConfirmation = nil } })) {
            Button("Delete", role: .destructive) {
                if let urls = deleteConfirmation { Task { await model.delete(urls: urls) } }
                deleteConfirmation = nil
            }
            Button("Cancel", role: .cancel) { deleteConfirmation = nil }
        } message: {
            Text("Delete \(deleteConfirmation?.count ?? 0) item(s)? This cannot be undone.")
        }
        .sheet(item: $infoItem) { item in
            FileMetadataSheet(item: item)
        }
        .sheet(item: $directoryPicker) { context in
            DirectoryPickerView(rootURL: model.rootURL,
                                service: model.service,
                                title: context.title) { destination in
                Task {
                    switch context.kind {
                    case .copy:
                        await model.copySelected(context.urls, to: destination)
                    case .move:
                        await model.moveSelected(context.urls, to: destination)
                    }
                }
            }
        }
        .fileImporter(isPresented: $importPicker,
                      allowedContentTypes: [.item],
                      allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let source = urls.first else { return }
            let accessed = source.startAccessingSecurityScopedResource()
            defer { if accessed { source.stopAccessingSecurityScopedResource() } }
            let stagedName = UUID().uuidString + "-" + source.lastPathComponent
            let stagedURL = FileManager.default.temporaryDirectory.appendingPathComponent(stagedName)
            do {
                try FileManager.default.copyItem(at: source, to: stagedURL)
                Task { await model.importFile(from: stagedURL) }
            } catch {
                model.errorMessage = ErrorHandler.present(error, context: "importFile")
            }
        }
        .sheet(item: Binding(
            get: { shareURL.map { ShareItem(url: $0) } },
            set: { if !$0 { shareURL = nil } })) { shareItem in
            ActivityShareSheet(items: [shareItem.url])
        }
        .sheet(item: Binding(
            get: { previewURL.map { ShareItem(url: $0) } },
            set: { if !$0 { previewURL = nil } })) { previewItem in
            QuickLookPreview(url: previewItem.url)
        }
        .fileImporter(isPresented: Binding(
            get: { replaceTarget != nil },
            set: { if !$0 { replaceTarget = nil } }),
            allowedContentTypes: [.data],
            allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let source = urls.first,
               let target = replaceTarget {
                Task { await model.replace(target: target, with: source) }
            }
            replaceTarget = nil
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if model.isLoading && model.items.isEmpty {
            ProgressView("Loading…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let message = model.errorMessage, model.items.isEmpty {
            errorState(message)
        } else if model.sortedItems.isEmpty {
            emptyState
        } else {
            fileList
        }
    }

    private func errorState(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Cannot open folder", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Refresh") { Task { await model.refresh() } }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Empty Folder", systemImage: "folder")
        } description: {
            Text("This folder contains no items. Use the ••• menu to create a folder or import a file.")
        }
    }

    private var fileList: some View {
        Group {
            switch model.viewMode {
            case .list:
                List {
                    ForEach(model.sortedItems) { item in
                        row(for: item)
                    }
                }
                .listStyle(.plain)
            case .grid:
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 12)], spacing: 12) {
                        ForEach(model.sortedItems) { item in
                            gridCell(for: item)
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
    }

    @ViewBuilder
    private func row(for item: FileItem) -> some View {
        Button {
            handleTap(item)
        } label: {
            FileRowView(item: item,
                        selectionMode: model.selection.isActive,
                        isSelected: model.selection.isSelected(item))
        }
        .buttonStyle(.plain)
        .contextMenu {
            FileContextMenu.menu(for: item) { action in
                handleContextAction(action, item: item)
            }
        }
        .previewContextMenuIfAvailable(item: item) { action in
            handleContextAction(action, item: item)
        }
    }

    @ViewBuilder
    private func gridCell(for item: FileItem) -> some View {
        Button {
            handleTap(item)
        } label: {
            FileGridCellView(item: item,
                             selectionMode: model.selection.isActive,
                             isSelected: model.selection.isSelected(item))
        }
        .buttonStyle(.plain)
        .contextMenu {
            FileContextMenu.menu(for: item) { action in
                handleContextAction(action, item: item)
            }
        }
    }

    private var selectionStatusBar: some View {
        HStack {
            Text("\(model.selection.count) selected")
                .font(.footnote.weight(.medium))
            Spacer()
            Button("Select All") { model.selectAll() }
                .font(.footnote)
            Button("Deselect All") { model.selection.deselectAll() }
                .font(.footnote)
            Button("Done") { model.selection.end() }
                .font(.footnote.weight(.semibold))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.thinMaterial)
    }
    // MARK: - Navigation helpers

    private func toolbarItems() -> some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) { backButton }
        ToolbarItem(placement: .principal) { breadcrumbMenu }
        ToolbarItem(placement: .topBarTrailing) { ellipsisMenu }
    }

    private var backButton: some View {
        Group {
            if let parent = model.goUpOne() {
                Button {
                    Task { await model.openDirectory(parent) }
                } label: {
                    Image(systemName: "chevron.left")
                }
                .accessibilityLabel("Back to \(parent.lastPathComponent)")
            }
        }
    }

    private var breadcrumbMenu: some View {
        Menu {
            ForEach(pathComponents, id: \.url) { component in
                Button(component.name) {
                    Task { await model.openDirectory(component.url) }
                }
            }
        } label: {
            Text(model.directoryTitle)
                .font(.headline)
        }
        .accessibilityLabel("Current folder \(model.directoryTitle), path menu")
    }

    private var pathComponents: [(name: String, url: URL)] {
        var components: [(String, URL)] = []
        var url = model.currentURL
        while url != model.rootURL.deletingLastPathComponent() {
            components.append((url == model.rootURL ? "Files" : url.lastPathComponent, url))
            guard url.pathComponents.count > 1 else { break }
            url = url.deletingLastPathComponent()
        }
        return components.reversed()
    }

    private var ellipsisMenu: some View {
        Menu {
            if model.selection.isActive {
                Button("Select All") { model.selectAll() }
                Button("Deselect All") { model.selection.deselectAll() }
                Button("Cancel Selection", role: .cancel) { model.selection.end() }
                Divider()
            } else {
                Button {
                    model.selection.begin()
                } label: {
                    Label("Select", systemImage: "checkmark.circle")
                }
            }
            Button {
                showNewFolderAlert = true
            } label: {
                Label("New Folder", systemImage: "folder.badge.plus")
            }
            Button {
                importPicker = true
            } label: {
                Label("Import File", systemImage: "square.and.arrow.down")
            }
            Button {
                Task { await model.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            Menu("Sort By") {
                ForEach(SortField.allCases, id: \.self) { field in
                    Button {
                        if model.sortField == field {
                            model.sortAscending.toggle()
                        } else {
                            model.sortField = field
                            model.sortAscending = true
                        }
                    } label: {
                        Label(field.rawValue,
                              systemImage: model.sortField == field
                              ? (model.sortAscending ? "chevron.up" : "chevron.down")
                              : "")
                    }
                }
            }
            Menu("View Options") {
                Picker("View as", selection: $model.viewMode) {
                    ForEach(ViewMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                Toggle("Show Hidden Files", isOn: $model.showHidden)
            }
            Button {
                if let first = model.selection.selectedItems(from: model.sortedItems).first {
                    infoItem = first
                } else {
                    Task {
                        if let info = try? await model.service.getFileMetadata(at: model.currentURL) {
                            infoItem = info
                        }
                    }
                }
            } label: {
                Label("Get Info", systemImage: "info.circle")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("More actions")
        .onChange(of: model.showHidden) { _, _ in Task { await model.refresh() } }
    }

    // MARK: - Interaction

    private func handleTap(_ item: FileItem) {
        if model.selection.isActive {
            model.toggleSelection(item)
            return
        }
        if item.isDirectory {
            Task { await model.openDirectory(item.url) }
        } else if item.url.pathExtension.lowercased() == "zip" {
            Task { await model.extract(archive: item.url) }
        } else {
            previewURL = item.url
        }
    }

    private func handleContextAction(_ action: FileContextAction, item: FileItem) {
        switch action {
        case .open: handleTap(item)
        case .copy:
            directoryPicker = DirectoryPickerContext(
                kind: .copy, title: "Copy to…", urls: [item.url])
        case .move:
            directoryPicker = DirectoryPickerContext(
                kind: .move, title: "Move to…", urls: [item.url])
        case .rename:
            renameTarget = item.url
            renameText = item.name
        case .compress:
            Task { await model.compressSelected([item]) }
        case .extract:
            Task { await model.extract(archive: item.url) }
        case .share:
            shareURL = item.url
        case .replace:
            replaceTarget = item.url
        case .duplicate:
            Task { await model.duplicate(item: item.url) }
        case .delete:
            deleteConfirmation = [item.url]
        case .getInfo:
            infoItem = item
        }
    }
}

private struct ShareItem: Identifiable {
    let url: URL
    var id: URL { url }
}

extension View {
    /// iOS 16+ contextMenuPreview hook kept optional to stay simulator-safe.
    func previewContextMenuIfAvailable(item: FileItem,
                                       onAction: @escaping (FileContextAction) -> Void) -> some View {
        self
    }
}
