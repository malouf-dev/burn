import AppKit
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
        var text = String(localized: "Burned \(Self.date(info.created)) by \(info.application) · \(info.fileCount) files, \(size)")
        if let set = source.set {
            text += " · " + String(localized: "disc \(set.disc) of \(set.discCount) of “\(set.name)”")
        }
        return text
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
            case .repairing, .restoring:
                Button("Stop") { model.cancel() }
                    .keyboardShortcut(.cancelAction)
            case .restored(_, let folder):
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                restoreButton
            case .repaired(_, let folder):
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                Button("Check Again") { model.check() }
                    .keyboardShortcut(.defaultAction)
            case .finished:
                if model.canRepair {
                    Button("Repair…") { chooseRepairFolder() }
                        .help("Copies the disc's files to a folder you choose, rebuilding damaged ones from the disc's recovery data")
                }
                restoreButton
                Button("Check Again") { model.check() }
                    .keyboardShortcut(.defaultAction)
            default:
                restoreButton
                Button("Check Files") { model.check() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.selected == nil || model.rows.isEmpty)
            }
        }
        .padding(12)
    }

    private var restoreButton: some View {
        Button("Restore…") { chooseRestoreFolder() }
            .help("Copies the disc's files back to a folder, checked against their checksums and repaired where needed. Files cut across a disc set are put back together as each disc is restored.")
            .disabled(model.selected == nil || model.rows.isEmpty)
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
        case .repairing(let fraction):
            HStack(spacing: 8) {
                ProgressView(value: fraction)
                    .frame(width: 160)
                Text("Repairing…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .restoring(let fraction):
            HStack(spacing: 8) {
                ProgressView(value: fraction)
                    .frame(width: 160)
                Text("Restoring…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .restored(let report, let folder):
            Label(Self.restoreSummary(report, folder: folder),
                  systemImage: report.isComplete ? "checkmark.seal.fill" : "xmark.seal.fill")
                .foregroundStyle(report.isComplete ? .green : .red)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        case .repaired(let report, let folder):
            if report.isComplete {
                Label(String(localized: "Repaired \(report.repaired.count) files. Every file is in “\(folder.lastPathComponent)”."),
                      systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            } else {
                Label(String(localized: "\(report.unrepairable.count) files are too damaged for the recovery data. The rest are in “\(folder.lastPathComponent)”."),
                      systemImage: "xmark.seal.fill")
                    .foregroundStyle(.red)
            }
        }
    }

    private func chooseRestoreFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = model.restoreFolder
        panel.prompt = String(localized: "Restore Here")
        panel.message = model.selected?.set == nil
            ? String(localized: "Choose where to put the disc's files. The disc itself isn't changed.")
            : String(localized: "Choose where to put the set's files. Restore every disc of the set into the same folder, in any order.")
        if panel.runModal() == .OK, let url = panel.url {
            model.restore(into: url)
        }
    }

    static func restoreSummary(_ report: RestoreReport, folder: URL) -> String {
        var text: String
        if let disc = report.disc, let count = report.discCount {
            text = String(localized: "Disc \(disc) of \(count) restored into “\(folder.lastPathComponent)”.")
            let missing = Set(1...count).subtracting(report.discsRestored).sorted()
            if missing.isEmpty {
                text += " " + String(localized: "Every disc of the set is in.")
            } else {
                text += " " + String(localized: "Still to restore: \(missing.map(String.init).joined(separator: ", ")).")
            }
        } else {
            text = String(localized: "\(report.restored.count) files restored into “\(folder.lastPathComponent)”.")
        }
        if !report.completed.isEmpty {
            text += " " + String(localized: "\(report.completed.count) cut files are whole again.")
        }
        if !report.repaired.isEmpty {
            text += " " + String(localized: "\(report.repaired.count) files were repaired on the way.")
        }
        if !report.damaged.isEmpty {
            text += " " + String(localized: "\(report.damaged.count) files are too damaged to restore; they're in “\(report.kept?.lastPathComponent ?? "")”.")
        }
        return text
    }

    private func chooseRepairFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Repair Here")
        panel.message = String(localized: "Choose where to put the repaired copy of the disc. The disc itself isn't changed.")
        if panel.runModal() == .OK, let url = panel.url {
            model.repair(into: url)
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
