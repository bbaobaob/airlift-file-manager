import SwiftUI

struct FilesView: View {
    @StateObject private var vm = FilesViewModel()
    @State private var newFolderName: String = ""
    @State private var showMkdir = false
    let columns = [GridItem(.adaptive(minimum: 90))]

    var body: some View {
        NavigationStack {
            VStack {
                HStack {
                    Button("Up") { vm.goUp() }.disabled(vm.currentPath == "/")
                    Text(vm.currentPath).font(.caption).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Picker("Sort", selection: $vm.sortKey) {
                        Text("Name").tag(FilesViewModel.SortKey.name)
                        Text("Date").tag(FilesViewModel.SortKey.date)
                        Text("Size").tag(FilesViewModel.SortKey.size)
                    }
                    .pickerStyle(.menu)
                    .onChange(of: vm.sortKey) { vm.refresh() }
                    Button(vm.layout == .list ? "Grid" : "List") {
                        vm.layout = vm.layout == .list ? .grid : .list
                    }
                }
                .padding(.horizontal)

                if let err = vm.errorMessage {
                    Text(err).font(.caption).foregroundStyle(.red).padding(.horizontal)
                }

                if vm.layout == .list {
                    List(vm.entries, selection: $vm.selection) { e in
                        HStack {
                            Image(systemName: e.isDirectory ? "folder" : "doc")
                            VStack(alignment: .leading) {
                                Text(e.name).lineLimit(1)
                                Text("\(e.size) B").font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { vm.enter(e) }
                        .contextMenu {
                            Button("Delete", role: .destructive) { vm.delete(e) }
                            if e.isDirectory { Button("Open") { vm.enter(e) } }
                        }
                    }
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns) {
                            ForEach(vm.entries) { e in
                                VStack {
                                    Image(systemName: e.isDirectory ? "folder" : "doc")
                                        .font(.largeTitle)
                                    Text(e.name).font(.caption).lineLimit(2)
                                }
                                .padding(8)
                                .background(vm.selection.contains(e.path) ? Color.accentColor.opacity(0.2) : Color.clear)
                                .cornerRadius(8)
                                .onTapGesture { vm.enter(e) }
                                .contextMenu {
                                    Button("Delete", role: .destructive) { vm.delete(e) }
                                }
                            }
                        }
                    }
                }
                Spacer()
                Text("Sandbox Documents/ only. /var/mobile/* → Requires Mac / UnsupportedOnDevice.")
                    .font(.caption2).foregroundStyle(.secondary).padding()
            }
            .navigationTitle("Files")
            .toolbar {
                Button("New Folder") { showMkdir = true }
            }
            .alert("New Folder", isPresented: $showMkdir) {
                TextField("Name", text: $newFolderName)
                Button("Create") { vm.mkdir(name: newFolderName.isEmpty ? "Untitled" : newFolderName); newFolderName = "" }
                Button("Cancel", role: .cancel) {}
            }
            .onAppear { vm.refresh() }
        }
    }
}

#Preview { FilesView() }
