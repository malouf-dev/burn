import MMC
import ISOBuilder
import SwiftUI

/// Asks for the disc's name and confirms the burn, with the options that go with it.
struct BurnSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.title2.weight(.semibold))

            if model.burningImage {
                EmptyView()
            } else if let set = model.discSet {
                Text("“\(set.volumeName(forDisc: model.setDiscNumber))”, from the plan for the set “\(set.name)”.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Disc name", text: $model.discName, prompt: Text("Name this disc"))
                        .textFieldStyle(.roundedBorder)
                        .focused($nameFocused)
                        .accessibilityLabel("Disc name")
                    Text("Up to \(AppModel.discNameLimit) characters. This is the name Finder shows for the disc.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text(summary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                // A disc image is copied as it is, so nothing can be added to it.
                if !model.burningImage {
                    Toggle("Add checksums, so the disc can be checked years from now", isOn: $model.includeChecksums)
                        .disabled(model.discSet != nil)
                    Toggle("Add recovery data, so damaged files can be repaired", isOn: $model.includeRecovery)
                        .disabled(!model.includeChecksums || model.discSet != nil)
                        .help("PAR2 recovery data in the hidden .burn folder, about \(AppModel.recoveryPercent)% of the files' size. Any PAR2 tool can use it.")
                    if model.recoveryOmitted {
                        Label(String(localized: "More than \(ISOImageBuilder.recoveryFileLimit.formatted()) files, so this disc can't carry recovery data. Checksums still cover every file."),
                              systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Toggle("Eject when done", isOn: $model.ejectWhenDone)
            }

            speed

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(model.willOverwrite ? "Erase and Burn" : "Burn") {
                    dismiss()
                    model.burn()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.speedsRead
                          || model.discSet == nil && !model.burningImage && model.discName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { nameFocused = true }
        .task { await model.readWriteSpeeds() }
    }

    /// The write speed: Default follows Settings, and a speed picked here is kept for this kind
    /// of disc.
    private var speed: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Speed", selection: $model.chosenSpeed) {
                Text(defaultTitle).tag(WriteSpeed?.none)
                if !model.offeredSpeeds.isEmpty {
                    Divider()
                }
                ForEach(model.offeredSpeeds, id: \.self) { speed in
                    Text(model.speedLabel(speed)).tag(WriteSpeed?.some(speed))
                }
            }
            .fixedSize()
            .disabled(model.offeredSpeeds.isEmpty)
            Text(speedNote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var defaultTitle: String {
        let setting = model.speedDefault == .fastest ? String(localized: "Fastest") : String(localized: "Slowest")
        guard model.speedsRead else { return String(localized: "Default: \(setting)") }
        guard let speed = model.speedDefault == .fastest ? model.offeredSpeeds.last : model.offeredSpeeds.first else {
            return String(localized: "The drive's choice")
        }
        return String(localized: "Default: \(setting), \(model.speedLabel(speed))")
    }

    private var speedNote: String {
        if !model.speedsRead { return String(localized: "Asking the drive which speeds it offers…") }
        if model.offeredSpeeds.isEmpty {
            return String(localized: "The drive doesn't say which speeds it offers for this disc, so it picks one itself.")
        }
        if model.chosenSpeed != nil, let type = model.speedDiscType {
            return String(localized: "Kept for \(type) discs. Choose Default to follow Settings again.")
        }
        return String(localized: "Default follows Settings. A speed picked here is kept for this kind of disc.")
    }

    private var title: String {
        if let set = model.discSet {
            return String(localized: "Burn Disc \(model.setDiscNumber) of \(set.discs.count)")
        }
        if model.burningImage {
            return model.willOverwrite ? String(localized: "Erase and Burn Disc Image") : String(localized: "Burn Disc Image")
        }
        return model.willOverwrite ? String(localized: "Erase and Burn") : String(localized: "Burn Disc")
    }

    private var summary: String {
        let bytes = model.nextSetDisc?.bytes ?? model.estimatedBytes
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        let media = model.writableDisc?.profile.name ?? ""
        var text = String(localized: "\(size) will be written to the \(media), then read back and checked block by block.")
        if model.burningImage, let image = model.discImage {
            text = String(localized: "“\(image.name)”, \(size), will be copied to the \(media) block for block, then read back and checked.")
        }
        if model.willOverwrite {
            let current = model.discVolume.map { "“\($0.name)”" } ?? String(localized: "what's on it")
            text = String(localized: "The disc is erased first, and \(current) is lost.") + " " + text
        }
        return text
    }
}
