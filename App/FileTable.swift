import AppKit
import QuickLookThumbnailing
import SwiftUI

/// One row in the Burn view's table: something added, or, inside an added folder, what it holds.
struct FileRow: Identifiable, Hashable {
    let id: URL
    let name: String
    let isDirectory: Bool
    /// Bytes, or nil while an added item is still being measured.
    let size: Int64?
    let modified: Date?
    let kind: String
    /// A reason this item can't be burned, shown in place of its size.
    let problem: String?

    init(item: DiscItem) {
        id = item.url
        name = item.name
        isDirectory = item.isDirectory
        size = item.size
        let values = try? item.url.resourceValues(forKeys: [.contentModificationDateKey, .localizedTypeDescriptionKey])
        modified = values?.contentModificationDate
        kind = values?.localizedTypeDescription ?? ""
        if item.unreadable {
            problem = String(localized: "Can't read")
        } else if item.hasFileTooLarge {
            problem = String(localized: "4 GB or larger")
        } else {
            problem = nil
        }
    }

    init(url: URL) {
        id = url
        name = url.lastPathComponent
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
                                                      .localizedTypeDescriptionKey])
        isDirectory = values?.isDirectory ?? false
        size = isDirectory ? nil : Int64(values?.fileSize ?? 0)
        modified = values?.contentModificationDate
        kind = values?.localizedTypeDescription ?? ""
        problem = nil
    }

    /// A folder's contents, read when the table asks, so large folders cost nothing until opened.
    var children: [FileRow]? {
        guard isDirectory else { return nil }
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: id, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: [.skipsHiddenFiles])) ?? []
        return contents
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map(FileRow.init(url:))
    }
}

/// The files to burn, as a native table with a thumbnail, kind, size and date for each.
struct FileTable: View {
    let rows: [FileRow]
    @Binding var selection: Set<URL>
    let onDelete: () -> Void

    var body: some View {
        Table(rows, children: \.children, selection: $selection) {
            TableColumn("Name") { row in
                HStack(spacing: 6) {
                    Thumbnail(url: row.id)
                    Text(row.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .width(min: 180, ideal: 320)
            TableColumn("Kind") { row in
                Text(row.kind)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 60, ideal: 120)
            TableColumn("Size") { row in
                SizeCell(row: row)
            }
            .width(min: 60, ideal: 80)
            TableColumn("Date Modified") { row in
                Text(row.modified?.formatted(date: .abbreviated, time: .shortened) ?? "")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 80, ideal: 150)
        }
        .onDeleteCommand(perform: onDelete)
    }
}

private struct SizeCell: View {
    let row: FileRow

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            if let problem = row.problem {
                Text(problem).foregroundStyle(.red)
            } else if let size = row.size {
                Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else {
                Text("—").foregroundStyle(.tertiary)
            }
        }
    }
}

/// A file's Quick Look thumbnail, with its Finder icon until the thumbnail is ready.
struct Thumbnail: View {
    let url: URL
    var side: CGFloat = 20
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 2)
                    .resizable()
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
            }
        }
        .aspectRatio(contentMode: .fit)
        .frame(width: side, height: side)
        .accessibilityHidden(true)
        .task(id: url) {
            image = await Self.thumbnail(for: url, side: side)
        }
    }

    nonisolated static func thumbnail(for url: URL, side: CGFloat) async -> CGImage? {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: side, height: side), scale: 2,
                                                   representationTypes: .thumbnail)
        return await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                continuation.resume(returning: representation?.cgImage)
            }
        }
    }
}
