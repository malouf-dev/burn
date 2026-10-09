import ISOBuilder
import SwiftUI

/// Shown under the files when the disc in the drive is from a set and no set is in progress.
/// The set is taken to be finished unless the user carries it on.
struct ContinueSetBanner: View {
    let info: DiscSetInfo
    let carryOn: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.stack.3d.up")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Disc \(info.disc) of \(info.discCount) of the set “\(info.name)”")
                    .font(.callout.weight(.semibold))
                Text("If there are discs still to burn, carry the set on from this disc.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Continue Set…", action: carryOn)
                .help("Make the set's plan again from this disc, then burn the discs still to come")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.4))
    }
}

/// Carries on with a set the app no longer has, from one of its discs (decision D16). The disc's
/// `set.json` gives the whole plan; the user says where the files are and which disc is next.
/// The disc in the drive is then ejected, ready for a blank.
struct ContinueSetSheet: View {
    @Bindable var model: AppModel
    let info: DiscSetInfo
    @Environment(\.dismiss) private var dismiss
    @State private var folder: URL?
    @State private var next: Int
    @State private var plan: DiscSetPlan?
    @State private var problems: [DiscSetPlan.FileProblem] = []
    @State private var failure: String?
    @State private var checking = false
    @State private var choosingFolder = false

    private struct Check: Equatable {
        let folder: URL?
        let next: Int
    }

    init(model: AppModel, info: DiscSetInfo) {
        self.model = model
        self.info = info
        _next = State(initialValue: min(info.disc + 1, info.discCount))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Continue “\(info.name)”")
                .font(.title2.weight(.semibold))
            Text("Disc \(info.disc) of \(info.discCount) is in the drive. Choose the folder the set was made from, and the disc to burn next. The disc in the drive is then ejected, ready for a blank.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Form {
                LabeledContent("Files") {
                    HStack {
                        Text(folder?.path ?? String(localized: "Not chosen yet"))
                            .foregroundStyle(folder == nil ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…") { choosingFolder = true }
                    }
                }
                Picker("Burn next", selection: $next) {
                    ForEach(1...max(1, info.discCount), id: \.self) { number in
                        Text("Disc \(number) of \(info.discCount)").tag(number)
                    }
                }
            }
            .formStyle(.columns)

            status
                .frame(minHeight: 36, alignment: .topLeading)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Continue Set") {
                    guard let plan else { return }
                    model.continueDiscSet(plan, at: next)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(plan == nil || checking || !problems.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { folder = url }
        }
        .task(id: Check(folder: folder, next: next)) { await check() }
    }

    @ViewBuilder
    private var status: some View {
        if checking {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Checking the files…")
                    .foregroundStyle(.secondary)
            }
        } else if let failure {
            Label(failure, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        } else if let problem = AppModel.describe(problems) {
            Label(problem, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        } else if plan != nil {
            Label(next == info.discCount
                    ? String(localized: "All the files for disc \(next) are there.")
                    : String(localized: "All the files for discs \(next) to \(info.discCount) are there."),
                  systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        }
    }

    /// Makes the plan again from the disc with the folder chosen, then checks the files the
    /// discs from the next one on need.
    private func check() async {
        guard let folder else { return }
        checking = true
        failure = nil
        defer { checking = false }
        do {
            let remade = try await model.remakeDiscSet(files: folder)
            let discs = next...remade.discs.count
            problems = await Task.detached(priority: .userInitiated) { remade.fileProblems(onDiscs: discs) }.value
            plan = remade
        } catch {
            plan = nil
            problems = []
            failure = "\(error)"
        }
    }
}
