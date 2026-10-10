import ISOBuilder
import MMC
import SwiftUI
import UniformTypeIdentifiers

/// What the window does, chosen from the toolbar.
enum Mode: String, CaseIterable, Identifiable {
    case burn
    case verify
    case restore
    var id: Self { self }
}

struct ContentView: View {
    @Bindable var model: AppModel
    let verifier: VerifyModel
    let restorer: RestoreModel
    @SceneStorage("mode") private var mode: Mode = .burn
    @AppStorage("showsLog") private var showsLog = false

    var body: some View {
        VStack(spacing: 0) {
            switch mode {
            case .burn: BurnView(model: model)
            case .verify: VerifyView(model: verifier)
            case .restore: RestoreView(model: restorer)
            }
            if showsLog {
                Divider()
                LogPanel(log: model.currentLog)
            }
        }
        .frame(minWidth: 640, minHeight: 480)
        .toolbar(removing: .title)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Mode", selection: $mode) {
                    Label("Burn", systemImage: "opticaldisc").tag(Mode.burn)
                    Label("Verify", systemImage: "checkmark.seal").tag(Mode.verify)
                    Label("Restore", systemImage: "tray.and.arrow.down").tag(Mode.restore)
                }
                .pickerStyle(.segmented)
                .labelStyle(.titleAndIcon)
                .accessibilityLabel("Mode")
                // The burn's progress lives in the Burn view, so stay there until it's done.
                .disabled(model.activity != .idle)
            }
            ToolbarItem(placement: .primaryAction) {
                Toggle(isOn: $showsLog) {
                    Label("Log", systemImage: "text.alignleft")
                }
                .toggleStyle(.button)
                .help("Show every command sent to the drive, with buttons to copy or save the log")
            }
        }
        // Verify starts on the disc in the drive, when it has checksums.
        .onChange(of: model.discVolume, initial: true) { _, volume in
            verifier.prefer(model.discHasChecksums ? volume?.url : nil)
        }
        // Restore starts discs on insert only while its view is open.
        .onChange(of: mode, initial: true) { _, mode in
            restorer.isShowing = mode == .restore
        }
    }
}

/// Burn's data view: the disc and what will go on it.
struct BurnView: View {
    @Bindable var model: AppModel
    @State private var selection = Set<URL>()
    @State private var showingImporter = false
    @State private var showingBurnSheet = false
    @State private var showingSetSheet = false
    /// The set being carried on from the disc in the drive, while its sheet is open.
    @State private var continuing: DiscSetInfo?
    @State private var confirmingErase = false
    @State private var confirmingCancel = false

    var body: some View {
        VStack(spacing: 0) {
            DriveHeader(model: model, confirmingErase: $confirmingErase)
            Divider()
            DiscHeader(model: model)
            fileList
            if let set = model.discSet, let disc = model.nextSetDisc {
                Divider()
                DiscSetBanner(set: set, disc: disc, problem: model.setFileProblemDetail) { model.cancelDiscSet() }
            } else if let info = model.discSetInfo {
                Divider()
                ContinueSetBanner(info: info) { continuing = info }
            }
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
        .sheet(isPresented: $showingBurnSheet) {
            BurnSheet(model: model)
        }
        .sheet(isPresented: $showingSetSheet) {
            DiscSetSheet(model: model)
        }
        .sheet(isPresented: Binding(get: { continuing != nil }, set: { if !$0 { continuing = nil } })) {
            if let continuing {
                ContinueSetSheet(model: model, info: continuing)
            }
        }
        .sheet(isPresented: .constant(model.activity != .idle)) {
            ProgressSheet(model: model, confirmingCancel: $confirmingCancel)
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
            FileTable(rows: model.rows, selection: $selection) {
                model.remove(urls: selection)
                selection.removeAll()
            }
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
                model.remove(urls: selection)
                selection.removeAll()
            } label: {
                Label("Remove", systemImage: "minus")
            }
            .disabled(selection.isEmpty || !model.items.contains { selection.contains($0.url) })

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

            if model.canSplitAcrossDiscs {
                Button("Split Across Discs…") { showingSetSheet = true }
                    .help("Plan a set of discs of one size, each filled to the last block, with the last disc holding what's left")
            }

            Button(burnTitle) { showingBurnSheet = true }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canBurn)
        }
        .padding(12)
    }

    private var burnTitle: String {
        if let set = model.discSet {
            return String(localized: "Burn Disc \(model.setDiscNumber) of \(set.discs.count)…")
        }
        return model.willOverwrite ? String(localized: "Erase and Burn…") : String(localized: "Burn…")
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
            if model.burningImage, let image = model.discImage {
                Text(image.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help("A disc image is burned as it is, so the disc takes its name from the image.")
            } else {
                TextField("Disc name", text: $model.discName, prompt: Text("Untitled"))
                    .textFieldStyle(.plain)
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: 260)
                    .disabled(model.discSet != nil)
                    .accessibilityLabel("Disc name")
                    .help("Up to \(AppModel.discNameLimit) characters. Older systems that read only Joliet see the first 16.")
            }
            Spacer()
            if model.discImage != nil && model.discSet == nil {
                Toggle("Disc Image", isOn: $model.burnsImageAsIs)
                    .toggleStyle(.checkbox)
                    .help("Copies the image to the disc block for block, so an install disc or other bootable disc works as the original did. Untick to put the file on a data disc instead.")
            }
            if !model.burningImage {
                Text("UDF + ISO 9660")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Readable on Mac, Windows and Linux, with files of any size. Older systems read the ISO 9660 copy, which leaves out files of 4 GB or more.")
                Toggle("Checksums", isOn: $model.includeChecksums)
                    .toggleStyle(.checkbox)
                    .disabled(model.discSet != nil)
                    .help("Adds a hidden .burn folder with a checksum for every file, so the disc can be checked in Verify, or with shasum, years from now.")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.4))
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
    @State private var confirmingAbandon = false

    var body: some View {
        if let held = model.heldBurn {
            heldView(held)
        } else {
            progressView
        }
    }

    /// A step failed every automatic try. Says what went wrong and what to check, and waits.
    private func heldView(_ held: HeldBurn) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(heldTitle(held.step)).font(.headline)
            Label(held.problem, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            Text(held.advice)
                .fixedSize(horizontal: false, vertical: true)
            Text("Burn tried \(held.tries) times. The drive and the disc are held as they are until you choose.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Abandon Burn…") { confirmingAbandon = true }
                Button("Try Again") { model.answerHeldBurn(.tryAgain) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .interactiveDismissDisabled()
        .confirmationDialog("Abandon the burn?", isPresented: $confirmingAbandon) {
            Button("Abandon Burn", role: .destructive) { model.answerHeldBurn(.abandon) }
            Button("Keep Waiting", role: .cancel) {}
        } message: {
            Text(model.isWriteOnceBurn
                 ? "The disc is ejected, and a write-once disc can't be used after an abandoned burn."
                 : "The disc is erased so it can be used again.")
        }
    }

    private func heldTitle(_ step: HeldBurn.Step) -> String {
        switch step {
        case .readingFiles: return String(localized: "Reading the files has stopped")
        case .writing: return String(localized: "Writing has stopped")
        case .closing: return String(localized: "Closing the disc has stopped")
        case .verifying: return String(localized: "Verifying has stopped")
        }
    }

    private var progressView: some View {
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
            if let retrying = model.retrying {
                Label(retrying, systemImage: "arrow.clockwise")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
        case .buildingImage, .preparingRecovery: return true
        case .burning(let progress): return progress.phase == .writing || progress.phase == .verifying
        default: return false
        }
    }

    private var title: String {
        switch model.activity {
        case .idle: return ""
        case .buildingImage: return String(localized: "Preparing the files…")
        case .preparingRecovery: return String(localized: "Making recovery data…")
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
        case .buildingImage(let fraction), .preparingRecovery(let fraction): return fraction
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
