import MMC
import SwiftUI

/// Asks for the disc's name and confirms the burn, with the options that go with it.
struct BurnSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.willOverwrite ? "Erase and Burn" : "Burn Disc")
                .font(.title2.weight(.semibold))

            VStack(alignment: .leading, spacing: 4) {
                TextField("Disc name", text: $model.discName, prompt: Text("Name this disc"))
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
                    .accessibilityLabel("Disc name")
                Text("Up to \(AppModel.discNameLimit) characters. This is the name Finder shows for the disc.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(summary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Add checksums, so the disc can be checked years from now", isOn: $model.includeChecksums)
                Toggle("Add recovery data, so damaged files can be repaired", isOn: $model.includeRecovery)
                    .disabled(!model.includeChecksums)
                    .help("PAR2 recovery data in the hidden .burn folder, about \(AppModel.recoveryPercent)% of the files' size. Any PAR2 tool can use it.")
                Toggle("Eject when done", isOn: $model.ejectWhenDone)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(model.willOverwrite ? "Erase and Burn" : "Burn") {
                    dismiss()
                    model.burn()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.discName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { nameFocused = true }
    }

    private var summary: String {
        let size = ByteCountFormatter.string(fromByteCount: model.estimatedBytes, countStyle: .file)
        let media = model.writableDisc?.profile.name ?? ""
        var text = String(localized: "\(size) will be written to the \(media), then read back and checked block by block.")
        if model.willOverwrite {
            let current = model.discVolume.map { "“\($0.name)”" } ?? String(localized: "what's on it")
            text = String(localized: "The disc is erased first, and \(current) is lost.") + " " + text
        }
        return text
    }
}
