import AppKit
import MMC
import SwiftUI

/// The drive's raw command log, live, with buttons to copy or save it for a bug report.
struct LogPanel: View {
    let log: CommandLog?
    @State private var text = ""

    /// Only the end is shown, since a long burn logs many lines. Copy and Save take all of it.
    private static let shownLines = 400

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Log")
                    .font(.headline)
                Text("Every command sent to the drive, and its answer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Copy Log") { copy() }
                    .disabled(log == nil)
                Button("Save to Desktop") { save() }
                    .disabled(log == nil)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
            ScrollView {
                Text(text.isEmpty ? String(localized: "Nothing logged yet.") : text)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(text.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .defaultScrollAnchor(.bottom)
        }
        .frame(height: 200)
        .background(.background)
        .task(id: log.map(ObjectIdentifier.init)) {
            while !Task.isCancelled {
                let lines = (log?.render() ?? "").split(separator: "\n", omittingEmptySubsequences: false)
                text = lines.suffix(Self.shownLines).joined(separator: "\n")
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(log?.render() ?? "", forType: .string)
    }

    private func save() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let stamp = formatter.string(from: Date())
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        let url = desktop.appendingPathComponent("Burn log \(stamp).txt")
        do {
            try (log?.render() ?? "").write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            NSSound.beep()
        }
    }
}
