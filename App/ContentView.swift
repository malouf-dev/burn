import MMC
import SwiftUI
import UniformTypeIdentifiers

/// The two things the window does, chosen from the toolbar.
enum Mode: String, CaseIterable, Identifiable {
    case burn
    case verify
    var id: Self { self }
}

struct ContentView: View {
    @Bindable var model: AppModel
    let verifier: VerifyModel
    @SceneStorage("mode") private var mode: Mode = .burn

    var body: some View {
        Group {
            switch mode {
            case .burn: BurnView(model: model)
            case .verify: VerifyView(model: verifier)
            }
        }
        .frame(minWidth: 560, minHeight: 480)
        .toolbar(removing: .title)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Mode", selection: $mode) {
                    Label("Burn", systemImage: "opticaldisc").tag(Mode.burn)
                    Label("Verify", systemImage: "checkmark.seal").tag(Mode.verify)
                }
                .pickerStyle(.segmented)
                .labelStyle(.titleAndIcon)
                .accessibilityLabel("Mode")
                // The burn's progress lives in the Burn view, so stay there until it's done.
                .disabled(model.activity != .idle)
            }
        }
    }
}

/// Burn's data view: the disc and what will go on it.
struct BurnView: View {
    @Bindable var model: AppModel
    @State private var selection = Set<DiscItem.ID>()
    @State private var showingImporter = false
    @State private var confirmingBurn = false
    @State private var confirmingErase = false
    @State private var confirmingCancel = false

    var body: some View {
        VStack(spacing: 0) {
            DriveHeader(model: model, confirmingErase: $confirmingErase)
            Divider()
            DiscHeader(model: model)
            fileList
            Divider()
            footer
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.item, .folder],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.add(urls) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.add(urls)
            return true
        }
        .sheet(isPresented: .constant(model.activity != .idle)) {
            ProgressSheet(model: model, confirmingCancel: $confirmingCancel)
        }
        .confirmationDialog(model.willOverwrite ? "Erase and burn this disc?" : "Burn this disc?",
                            isPresented: $confirmingBurn) {
            Button(model.willOverwrite ? "Erase and Burn" : "Burn", role: model.willOverwrite ? .destructive : nil) {
                model.burn()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(burnSummary)
        }
        .confirmationDialog("Erase this disc?", isPresented: $confirmingErase) {
            Button("Erase", role: .destructive) { model.erase() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Everything on the disc will be lost.")
        }
        .alert(model.outcome?.title ?? "", isPresented: outcomeBinding, presenting: model.outcome) { outcome in
            if !outcome.succeeded {
                Button("Copy Diagnostic Report") { model.copyDiagnosticReport() }
            }
            Button("OK", role: .cancel) {}
        } message: { outcome in
            Text(outcome.detail)
        }
    }

    private var outcomeBinding: Binding<Bool> {
        Binding(get: { model.outcome != nil && model.activity == .idle },
                set: { if !$0 { model.outcome = nil } })
    }

    private var burnSummary: String {
        let size = ByteCountFormatter.string(fromByteCount: model.estimatedBytes, countStyle: .file)
        let media = model.writableDisc?.profile.name ?? ""
        var written = String(localized: "\(size) will be written to the \(media) as “\(model.discName)”, then checked block by block.")
        if model.willOverwrite {
            let current = model.discVolume.map { "“\($0.name)”" } ?? String(localized: "what's on it")
            written = String(localized: "The disc is erased first, and \(current) is lost.") + " " + written
        }
        guard model.includeChecksums else { return written }
        return written + " " + String(localized: "A checksum for every file goes on the disc too, so you can check it again in Verify years from now.")
    }

    @ViewBuilder
    private var fileList: some View {
        if model.items.isEmpty {
            ContentUnavailableView {
                Label("No Files", systemImage: "doc.on.doc")
            } description: {
                Text("Drag files and folders here, or click Add.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(selection: $selection) {
                ForEach(model.items) { item in
                    if item.isDirectory {
                        DisclosureGroup {
                            FolderContents(url: item.url)
                        } label: {
                            ItemRow(item: item)
                        }
                        .tag(item.id)
                    } else {
                        ItemRow(item: item)
                            .tag(item.id)
                    }
                }
            }
            .onDeleteCommand { model.remove(selection) }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button {
                showingImporter = true
            } label: {
                Label("Add", systemImage: "plus")
            }
            .keyboardShortcut("o", modifiers: .command)

            Button {
                model.remove(selection)
                selection.removeAll()
            } label: {
                Label("Remove", systemImage: "minus")
            }
            .disabled(selection.isEmpty)

            Spacer()

            CapacityView(model: model)

            if let reason = model.burnBlocker, model.activity == .idle {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: 220, alignment: .trailing)
                    .multilineTextAlignment(.trailing)
            }

            Toggle("Eject when done", isOn: $model.ejectWhenDone)
                .toggleStyle(.checkbox)

            Button(model.willOverwrite ? "Erase and Burn" : "Burn") { confirmingBurn = true }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canBurn)
        }
        .padding(12)
    }
}

/// The disc as the root of what's being burned, as in Burn: its name, format and options.
struct DiscHeader: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "opticaldisc")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Disc name", text: $model.discName)
                .textFieldStyle(.plain)
                .font(.title3.weight(.semibold))
                .frame(maxWidth: 260)
                .accessibilityLabel("Disc name")
                .help("Up to \(AppModel.discNameLimit) characters, the most this disc format holds for a name.")
            Spacer()
            Text("ISO 9660 + Joliet")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("Readable on Mac, Windows and Linux. Files must be under 4 GB each.")
            Toggle("Checksums", isOn: $model.includeChecksums)
                .toggleStyle(.checkbox)
                .help("Adds a hidden .burn folder with a checksum for every file, so the disc can be checked in Verify, or with shasum, years from now.")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.4))
    }
}

/// One file or folder in the list. With no size, a spinner shows while `measuring`.
struct ItemRow: View {
    let name: String
    let isDirectory: Bool
    let size: Int64?
    var measuring = true
    var problem: String?

    init(name: String, isDirectory: Bool, size: Int64?, measuring: Bool = true) {
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.measuring = measuring
    }

    init(item: DiscItem) {
        self.init(name: item.name, isDirectory: item.isDirectory, size: item.size)
        if item.unreadable {
            problem = String(localized: "Can't read")
        } else if item.hasFileTooLarge {
            problem = String(localized: "4 GB or larger")
        }
    }

    var body: some View {
        HStack {
            Image(systemName: isDirectory ? "folder" : "doc")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if let problem {
                Text(problem)
                    .foregroundStyle(.red)
            } else if let size {
                Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else if measuring {
                ProgressView().controlSize(.small)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// What's inside an added folder, read when the folder is opened. For looking only.
struct FolderContents: View {
    let url: URL

    var body: some View {
        ForEach(children, id: \.self) { child in
            let isDirectory = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory {
                DisclosureGroup {
                    FolderContents(url: child)
                } label: {
                    ItemRow(name: child.lastPathComponent, isDirectory: true, size: nil, measuring: false)
                }
            } else {
                let size = Int64((try? child.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                ItemRow(name: child.lastPathComponent, isDirectory: false, size: size)
            }
        }
    }

    private var children: [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                                                                     options: [.skipsHiddenFiles])) ?? []
        return contents.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}

/// The drive and the disc in it.
struct DriveHeader: View {
    @Bindable var model: AppModel
    @Binding var confirmingErase: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "opticaldiscdrive")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                if model.drives.count > 1 {
                    Picker("Drive", selection: $model.selectedDriveID) {
                        ForEach(model.drives) { drive in
                            Text(drive.name).tag(Optional(drive.id))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                } else {
                    Text(model.drives.first?.name ?? String(localized: "No disc burner"))
                        .font(.headline)
                }
                Text(statusText)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if case .disc(let disc) = model.driveState, disc.writability == .needsErase {
                Button("Erase…") { confirmingErase = true }
            }
            if model.hasDrive {
                Button {
                    model.eject()
                } label: {
                    Label("Eject", systemImage: "eject")
                }
            }
        }
        .padding(12)
        .accessibilityElement(children: .contain)
    }

    private var statusText: String {
        guard model.hasDrive else { return String(localized: "Connect a disc burner.") }
        switch model.driveState {
        case nil:
            return String(localized: "Checking the drive…")
        case .noDisc?:
            return String(localized: "Insert a blank disc.")
        case .becomingReady?:
            return String(localized: "Reading the disc…")
        case .disc(let disc)?:
            let free = ByteCountFormatter.string(fromByteCount: disc.freeBytes, countStyle: .file)
            let used = ByteCountFormatter.string(fromByteCount: disc.usedBytes, countStyle: .file)
            let name = model.discVolume.map { "“\($0.name)”, " } ?? ""
            let checksums = model.discHasChecksums ? " " + String(localized: "Has checksums: check it in Verify.") : ""
            switch disc.writability {
            case .blank:
                return String(localized: "Blank \(disc.profile.name), \(free) free")
            case .needsErase where disc.canOverwrite:
                return String(localized: "\(disc.profile.name) with data: \(name)\(used). Burning erases it first.") + checksums
            case .needsErase:
                return String(localized: "This \(disc.profile.name) has data on it: \(name)\(used).") + checksums
            case .appendable, .notWritable:
                return String(localized: "\(disc.profile.name), already burned: \(name)\(used).") + checksums
            case .unsupported:
                return String(localized: "This version can't write \(disc.profile.name) discs yet.")
            }
        }
    }
}

/// How much of the disc the files will use.
struct CapacityView: View {
    let model: AppModel

    var body: some View {
        if let disc = model.blankDisc, !model.items.isEmpty {
            capacity(disc)
        } else if model.willOverwrite, !model.items.isEmpty {
            Text(ByteCountFormatter.string(fromByteCount: model.estimatedBytes, countStyle: .file))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .help("The disc's free space is known once it's erased.")
        }
    }

    private func capacity(_ disc: DiscState) -> some View {
        let fraction = min(1, Double(model.estimatedBytes) / Double(max(1, disc.freeBytes)))
        let used = ByteCountFormatter.string(fromByteCount: model.estimatedBytes, countStyle: .file)
        let free = ByteCountFormatter.string(fromByteCount: disc.freeBytes, countStyle: .file)
        return VStack(alignment: .trailing, spacing: 2) {
            ProgressView(value: fraction)
                .tint(model.fits ? Color.accentColor : Color.red)
                .frame(width: 120)
            Text("\(used) of \(free)")
                .font(.caption)
                .foregroundStyle(model.fits ? Color.secondary : Color.red)
                .monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.fits ? "\(used) of \(free) used" : "Too much for this disc: \(used) of \(free)")
    }
}

/// Shown while building, burning, verifying or erasing.
struct ProgressSheet: View {
    let model: AppModel
    @Binding var confirmingCancel: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            if let fraction {
                ProgressView(value: fraction)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            HStack {
                Spacer()
                if canCancel {
                    Button("Cancel") {
                        if model.isWriteOnceBurn, isWriting { confirmingCancel = true } else { model.cancel() }
                    }
                    .keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(20)
        .frame(width: 380)
        .interactiveDismissDisabled()
        .confirmationDialog("Stop the burn?", isPresented: $confirmingCancel) {
            Button("Stop Burning", role: .destructive) { model.cancel() }
            Button("Keep Burning", role: .cancel) {}
        } message: {
            Text("A write-once disc can't be used after a stopped burn.")
        }
    }

    private var isWriting: Bool {
        if case .burning(let progress) = model.activity { return progress.phase == .writing }
        return false
    }

    private var canCancel: Bool {
        switch model.activity {
        case .buildingImage: return true
        case .burning(let progress): return progress.phase == .writing || progress.phase == .verifying
        default: return false
        }
    }

    private var title: String {
        switch model.activity {
        case .idle: return ""
        case .buildingImage: return String(localized: "Preparing the files…")
        case .erasing: return String(localized: "Erasing the disc…")
        case .burning(let progress):
            switch progress.phase {
            case .preparing: return String(localized: "Getting the drive ready…")
            case .erasing: return String(localized: "Erasing the disc…")
            case .writing: return String(localized: "Writing…")
            case .closing: return String(localized: "Closing the disc…")
            case .verifying: return String(localized: "Verifying…")
            }
        }
    }

    private var fraction: Double? {
        switch model.activity {
        case .buildingImage(let fraction): return fraction
        case .burning(let progress) where !progress.isIndeterminate:
            return progress.fraction
        default: return nil
        }
    }

    private var detail: String {
        guard let fraction else { return "" }
        return fraction.formatted(.percent.precision(.fractionLength(0)))
    }
}
