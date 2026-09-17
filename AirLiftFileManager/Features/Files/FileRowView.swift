import SwiftUI

struct FileRowView: View {
    let item: FileItem
    let selectionMode: Bool
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            if selectionMode {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .font(.title3)
                    .accessibilityHidden(true)
            }
            Image(systemName: item.fileKindIcon)
                .font(.title2)
                .foregroundStyle(item.isDirectory ? Color.blue : Color.secondary)
                .frame(width: 30)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.body)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(item.typeLabel)
                    if !item.isDirectory {
                        Text(Formatters.fileSize(item.size))
                    }
                    Text(Formatters.date(item.modificationDate))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
            if item.isHidden {
                Image(systemName: "eye.slash")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("Hidden item")
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var parts = [item.isDirectory ? "Folder" : "File", item.name]
        if !item.isDirectory {
            parts.append(Formatters.fileSize(item.size))
        }
        if isSelected { parts.append("selected") }
        return parts.joined(separator: ", ")
    }
}

struct FileGridCellView: View {
    let item: FileItem
    let selectionMode: Bool
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.blue.opacity(item.isDirectory ? 0.2 : 0.08))
                Image(systemName: item.fileKindIcon)
                    .font(.system(size: 28))
                    .foregroundStyle(item.isDirectory ? Color.blue : Color.secondary)
                if selectionMode {
                    VStack {
                        HStack {
                            Spacer()
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                                .background(Circle().fill(.thinMaterial))
                                .padding(4)
                        }
                        Spacer()
                    }
                }
            }
            .frame(height: 68)
            Text(item.name)
                .font(.caption)
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.center)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.isDirectory ? "Folder" : "File"), \(item.name)")
    }
}
