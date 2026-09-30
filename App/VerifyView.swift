import ISOBuilder
import SwiftUI
import UniformTypeIdentifiers

/// Checks one disc at a time against the `.burn` checksum folder on it (decision D12), listing
/// every file with a tick or a cross, laid out like the Burn view.
struct VerifyView: View {
    @Bindable var model: VerifyModel
    @State private var choosingFolder = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            fileList
            Divider()
            footer
        }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder, .volume]) { result in
            if case .success(let url) = result { model.choose(url) }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                if model.sources.count > 1 {
                    Picker("Disc", selection: $model.selectedID) {
                        ForEach(model.sources) { source in
                            Text(source.info?.discName ?? source.name).tag(Optional(source.id))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(model.isChecking)
                } else {
                    Text(model.selected.map { $0.info?.discName ?? $0.name } ?? String(localized: "No disc to check"))
                        .font(.headline)
                }
                Text(detail)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Choose…") { choosingFolder = true }
                .help("Check a mounted disc image, or a folder holding a copy of a disc with its .burn folder")
                .disabled(model.isChecking)
        }
        .padding(12)
    }

    private var detail: String {
        guard let source = model.selected else {
            return String(localized: "Insert a disc burned with checksums, or open its disc image.")
        }
        guard let info = source.info else { return source.url.path }
        let size = ByteCountFormatter.string(fromByteCount: Int64(clamping: info.totalBytes), countStyle: .file)
        return String(localized: "Burned \(Self.date(info.created)) by \(info.application) · \(info.fileCount) files, \(size)")
    }

    // MARK: - Files

    @ViewBuilder
    private var fileList: some View {
        if model.selected == nil {
            ContentUnavailableView {
                Label("No Disc to Check", systemImage: "checkmark.seal")
            } description: {
                Text("Discs burned with checksums carry a hidden .burn folder. Checking reads every file and compares it with the checksum made when the disc was burned.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Table(model.rows) {
                TableColumn("") { row in
                    StatusIcon(status: row.status)
                }
                .width(24)
                TableColumn("Name") { row in
                    Text(row.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(row.id)
                }
                .width(min: 160, ideal: 260)
                TableColumn("Folder") { row in
                    Text(row.folder)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                .width(min: 80, ideal: 180)
                TableColumn("Size") { row in
                    HStack {
                        Spacer(minLength: 0)
                        Text(row.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .width(min: 60, ideal: 80)
                TableColumn("Result") { row in
                    Text(Self.label(row.status))
                        .foregroundStyle(Self.color(row.status))
                }
                .width(min: 80, ideal: 140)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            summary
            Spacer()
            switch model.phase {
            case .checking:
                Button("Stop") { model.cancel() }
                    .keyboardShortcut(.cancelAction)
            case .finished:
                Button("Check Again") { model.check() }
                    .keyboardShortcut(.defaultAction)
            default:
                Button("Check Files") { model.check() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.selected == nil || model.rows.isEmpty)
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private var summary: some View {
        switch model.phase {
        case .idle:
            if model.selected != nil {
                Text("\(model.rows.count) files to check")
                    .foregroundStyle(.secondary)
            }
        case .checking(let progress):
            HStack(spacing: 8) {
                ProgressView(value: progress.fraction)
                    .frame(width: 160)
                Text("\(progress.checkedFiles) of \(progress.totalFiles) files")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        case .finished(let report):
            if report.isIntact {
                Label(String(localized: "All \(report.matched.count) files match their checksums."),
                      systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            } else {
                let problems = report.changed.count + report.missing.count + report.unreadable.count
                Label(String(localized: "\(problems) of \(report.checkedCount) files don't match."),
                      systemImage: "xmark.seal.fill")
                    .foregroundStyle(.red)
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        }
    }

    // MARK: - Formatting

    static func label(_ status: VerifyModel.Status) -> String {
        switch status {
        case .pending: return ""
        case .matched: return String(localized: "Matches")
        case .changed: return String(localized: "Changed")
        case .missing: return String(localized: "Missing")
        case .unreadable: return String(localized: "Couldn't be read")
        case .unexpected: return String(localized: "Not in the list")
        }
    }

    static func color(_ status: VerifyModel.Status) -> Color {
        switch status {
        case .pending: return .secondary
        case .matched: return .green
        case .changed, .missing, .unreadable: return .red
        case .unexpected: return .orange
        }
    }

    static func date(_ text: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: text) else { return text }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

/// A tick, a cross, or a hollow circle while a file waits to be checked.
struct StatusIcon: View {
    let status: VerifyModel.Status

    var body: some View {
        Image(systemName: symbol)
            .foregroundStyle(VerifyView.color(status))
            .accessibilityLabel(VerifyView.label(status).isEmpty ? String(localized: "Not checked yet") : VerifyView.label(status))
    }

    private var symbol: String {
        switch status {
        case .pending: return "circle"
        case .matched: return "checkmark.circle.fill"
        case .changed, .unreadable: return "xmark.circle.fill"
        case .missing: return "questionmark.circle.fill"
        case .unexpected: return "plus.circle.fill"
        }
    }
}
