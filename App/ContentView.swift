import MMC
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
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
            fileList
            Divider()
            footer
        }
        .frame(minWidth: 560, minHeight: 420)
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
        .confirmationDialog("Burn this disc?", isPresented: $confirmingBurn) {
            Button("Burn") { model.burn() }
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
        let media = model.blankDisc?.profile.name ?? ""
        return String(localized: "\(size) will be written to the \(media) as “\(model.discName)”, then checked block by block.")
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
                    HStack {
                        Image(systemName: item.isDirectory ? "folder" : "doc")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text(item.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        if let size = item.size {
                            Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .accessibilityElement(children: .combine)
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

            TextField("Disc name", text: $model.discName)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 200)
                .accessibilityLabel("Disc name")

            Spacer()

            CapacityView(model: model)

            Toggle("Eject when done", isOn: $model.ejectWhenDone)
                .toggleStyle(.checkbox)

            Button("Burn") { confirmingBurn = true }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canBurn)
        }
        .padding(12)
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
            switch disc.writability {
            case .blank: return String(localized: "Blank \(disc.profile.name), \(free) free")
            case .needsErase: return String(localized: "This \(disc.profile.name) has data on it.")
            case .appendable: return String(localized: "This disc already has data on it. Adding to it comes later.")
            case .unsupported: return String(localized: "This version can't write \(disc.profile.name) discs yet.")
            case .notWritable: return String(localized: "This disc can't be written.")
            }
        }
    }
}

/// How much of the disc the files will use.
struct CapacityView: View {
    let model: AppModel

    var body: some View {
        if let disc = model.blankDisc, !model.items.isEmpty {
            let fraction = min(1, Double(model.estimatedBytes) / Double(max(1, disc.freeBytes)))
            let used = ByteCountFormatter.string(fromByteCount: model.estimatedBytes, countStyle: .file)
            let free = ByteCountFormatter.string(fromByteCount: disc.freeBytes, countStyle: .file)
            VStack(alignment: .trailing, spacing: 2) {
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
