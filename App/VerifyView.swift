import ISOBuilder
import SwiftUI
import UniformTypeIdentifiers

/// Checks a disc burned with checksums against the `.burn` folder on it (decision D12).
struct VerifyView: View {
    @Bindable var model: VerifyModel
    @State private var choosingFolder = false

    var body: some View {
        HStack(spacing: 0) {
            discList
                .frame(width: 230)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { model.choose(url) }
        }
    }

    // MARK: - Discs

    private var discList: some View {
        VStack(spacing: 0) {
            if model.volumes.isEmpty {
                ContentUnavailableView {
                    Label("No Discs to Check", systemImage: "checkmark.seal")
                } description: {
                    Text("Insert a disc burned with checksums.")
                }
            } else {
                List(model.volumes, selection: $model.selectedID) { volume in
                    VStack(alignment: .leading, spacing: 2) {
                        Label(volume.name, systemImage: "opticaldisc")
                            .lineLimit(1)
                        if let info = volume.info {
                            Text(Self.summary(info))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            Divider()
            HStack {
                Button("Choose Folder…") { choosingFolder = true }
                    .help("Check a folder that holds a copy of a disc, with its .burn folder.")
                Spacer()
                Button {
                    model.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .labelStyle(.iconOnly)
                .help("Look for discs again")
            }
            .padding(8)
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let volume = model.selected {
            VStack(alignment: .leading, spacing: 16) {
                header(volume)
                Divider()
                stateView(volume)
                Spacer(minLength: 0)
            }
            .padding(20)
        } else {
            ContentUnavailableView {
                Label("Check a Disc", systemImage: "checkmark.seal")
            } description: {
                Text("Discs burned with checksums carry a hidden .burn folder. Checking reads every file and compares it with the checksum made when the disc was burned.")
            }
        }
    }

    private func header(_ volume: VerifyModel.Volume) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(volume.info?.discName ?? volume.name)
                .font(.title2.weight(.semibold))
            if let info = volume.info {
                Text("Burned \(Self.date(info.created)) by \(info.application)")
                    .foregroundStyle(.secondary)
                Text(Self.summary(info))
                    .foregroundStyle(.secondary)
            }
            Text(volume.url.path)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func stateView(_ volume: VerifyModel.Volume) -> some View {
        switch model.state {
        case .idle:
            VStack(alignment: .leading, spacing: 12) {
                Text("Reads every file on the disc and compares it with its checksum.")
                    .foregroundStyle(.secondary)
                Button("Check Files") { model.check() }
                    .keyboardShortcut(.defaultAction)
            }
        case .checking(let progress):
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: progress.fraction)
                Text("\(progress.checkedFiles) of \(progress.totalFiles) files")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button("Stop") { model.cancel() }
                    .keyboardShortcut(.cancelAction)
            }
        case .finished(let report):
            ResultView(report: report) { model.check() }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 12) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                Button("Try Again") { model.check() }
            }
        }
    }

    // MARK: - Formatting

    static func summary(_ info: DiscInfo) -> String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(clamping: info.totalBytes), countStyle: .file)
        return String(localized: "\(info.fileCount) files, \(size)")
    }

    static func date(_ text: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: text) else { return text }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

/// What a check found.
struct ResultView: View {
    let report: ChecksumReport
    let checkAgain: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if report.isIntact {
                Label(String(localized: "All \(report.matched.count) files match their checksums."),
                      systemImage: "checkmark.seal.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
            } else {
                let problems = report.changed.count + report.missing.count + report.unreadable.count
                Label(String(localized: "\(problems) of \(report.checkedCount) files don't match."),
                      systemImage: "xmark.seal.fill")
                    .font(.headline)
                    .foregroundStyle(.red)
            }
            if !report.changed.isEmpty || !report.missing.isEmpty || !report.unreadable.isEmpty
                || !report.unexpected.isEmpty {
                List {
                    section(String(localized: "Changed"), report.changed)
                    section(String(localized: "Missing"), report.missing)
                    section(String(localized: "Couldn't be read"), report.unreadable)
                    section(String(localized: "Not in the checksum list"), report.unexpected)
                }
                .frame(minHeight: 160)
            }
            Button("Check Again", action: checkAgain)
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ paths: [String]) -> some View {
        if !paths.isEmpty {
            Section(title) {
                ForEach(paths, id: \.self) { path in
                    Text(path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
        }
    }
}
