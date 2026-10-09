import AppKit
import ISOBuilder
import SwiftUI

/// Copies Burn discs back into one folder: single discs, or a disc set one disc at a time,
/// checked against their checksums, repaired from their recovery data, with cut files rejoined
/// (decision D16). Ends with an optional comparison against the original folder.
struct RestoreView: View {
    @Bindable var model: RestoreModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Restore to")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(model.destination?.path ?? String(localized: "No folder chosen"))
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if let destination = model.destination {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([destination]) }
            }
            Button("Choose…") { chooseDestination() }
                .disabled(model.isBusy)
        }
        .padding(12)
    }

    // MARK: - Discs, sets and results

    private var content: some View {
        List {
            Section("Discs") {
                if model.discs.isEmpty {
                    Text("Insert a disc burned with checksums.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.discs) { disc in
                    discRow(disc)
                }
            }
            if !model.sets.isEmpty {
                Section("Sets in this folder") {
                    ForEach(model.sets) { set in
                        setRow(set)
                    }
                }
            }
            if !model.done.isEmpty {
                Section("Restored") {
                    ForEach(model.done) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name)
                                .font(.callout.weight(.semibold))
                            Label(Self.summary(item.report),
                                  systemImage: item.report.isComplete ? "checkmark.seal.fill" : "xmark.seal.fill")
                                .font(.caption)
                                .foregroundStyle(item.report.isComplete ? .green : .red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func discRow(_ disc: VerifyModel.Source) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "opticaldisc")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(disc.info?.discName ?? disc.name)
                if let set = disc.set {
                    Text("Disc \(set.disc) of \(set.discCount) of “\(set.name)”")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if model.isRestored(disc) {
                Label("In the folder", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
            }
            Button("Restore") { model.restore(disc) }
                .disabled(model.destination == nil || model.isBusy)
        }
    }

    private func setRow(_ set: DiscSetProgress) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(set.name)
                    .font(.callout.weight(.semibold))
                Spacer()
                Text(set.isComplete
                     ? String(localized: "Every disc is in")
                     : String(localized: "Next: insert disc \(set.missing[0])"))
                    .font(.caption)
                    .foregroundStyle(set.isComplete ? .green : .secondary)
            }
            HStack(spacing: 4) {
                ForEach(1...max(1, set.discCount), id: \.self) { number in
                    let restored = set.discsRestored.contains(number)
                    Text("\(number)")
                        .font(.caption.monospacedDigit())
                        .frame(minWidth: 22, minHeight: 18)
                        .background(restored ? Color.green.opacity(0.25) : Color.secondary.opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 4))
                        .accessibilityLabel(restored ? String(localized: "Disc \(number), restored")
                                                     : String(localized: "Disc \(number), not yet"))
                }
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            status
            Spacer()
            Toggle("Start when a disc is inserted", isOn: $model.startsOnInsert)
                .help("While this view is open, restores each disc of a set as soon as it's inserted, if it isn't in the folder yet")
            Toggle("Eject when done", isOn: $model.ejectsWhenDone)
            if model.isBusy {
                Button("Stop") { model.cancel() }
                    .keyboardShortcut(.cancelAction)
            } else {
                Button("Compare with Original…") { chooseOriginal() }
                    .help("Checks every restored file against the folder it was burned from, byte for byte")
                    .disabled(model.destination == nil)
            }
        }
        .toggleStyle(.checkbox)
        .padding(12)
    }

    @ViewBuilder
    private var status: some View {
        switch model.phase {
        case .idle:
            EmptyView()
        case .restoring(let name, let fraction):
            HStack(spacing: 8) {
                ProgressView(value: fraction)
                    .frame(width: 140)
                Text("Restoring “\(name)”…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        case .comparing(let fraction):
            HStack(spacing: 8) {
                ProgressView(value: fraction)
                    .frame(width: 140)
                Text("Comparing…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .compared(let comparison, let original):
            if comparison.isIdentical {
                Label(String(localized: "All \(comparison.matching.count) files match “\(original.lastPathComponent)”."),
                      systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            } else {
                Label(Self.differences(comparison, original: original), systemImage: "xmark.seal.fill")
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }

    // MARK: - Choosing folders

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = model.destination
        panel.prompt = String(localized: "Restore Here")
        panel.message = String(localized: "Choose where to put the discs' files. Restore every disc of a set into the same folder, in any order.")
        if panel.runModal() == .OK, let url = panel.url {
            model.destination = url
        }
    }

    private func chooseOriginal() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = String(localized: "Compare")
        panel.message = String(localized: "Choose the folder the discs were burned from.")
        if panel.runModal() == .OK, let url = panel.url {
            model.compare(with: url)
        }
    }

    // MARK: - Wording

    static func summary(_ report: RestoreReport) -> String {
        var parts: [String] = []
        if let disc = report.disc, let count = report.discCount {
            parts.append(String(localized: "Disc \(disc) of \(count): \(report.restored.count) files and \(report.partsPlaced.count) parts."))
        } else {
            parts.append(String(localized: "\(report.restored.count) files."))
        }
        if !report.completed.isEmpty {
            parts.append(String(localized: "\(report.completed.count) cut files are whole again."))
        }
        if report.rereads > 0 {
            parts.append(String(localized: "\(report.rereads) pieces read correctly on a second try."))
        }
        if !report.repaired.isEmpty {
            parts.append(String(localized: "\(report.repaired.count) files repaired from recovery data."))
        }
        if !report.damaged.isEmpty {
            let lost = report.unreadableBytes.values.reduce(0, +)
            var text = String(localized: "\(report.damaged.count) files are too damaged to restore")
            if lost > 0 {
                text += " " + String(localized: "(\(ByteCountFormatter.string(fromByteCount: Int64(lost), countStyle: .file)) unreadable)")
            }
            text += String(localized: "; what could be read is in “\(report.kept?.lastPathComponent ?? "")”.")
            parts.append(text)
        }
        return parts.joined(separator: " ")
    }

    static func differences(_ comparison: FolderComparison, original: URL) -> String {
        var parts = [String(localized: "Compared with “\(original.lastPathComponent)”: \(comparison.matching.count) match.")]
        if !comparison.differing.isEmpty {
            parts.append(String(localized: "\(comparison.differing.count) differ, such as \(comparison.differing[0])."))
        }
        if !comparison.onlyInOriginal.isEmpty {
            parts.append(String(localized: "\(comparison.onlyInOriginal.count) aren't restored, such as \(comparison.onlyInOriginal[0])."))
        }
        if !comparison.onlyInCopy.isEmpty {
            parts.append(String(localized: "\(comparison.onlyInCopy.count) are only in the restore, such as \(comparison.onlyInCopy[0])."))
        }
        return parts.joined(separator: " ")
    }
}
