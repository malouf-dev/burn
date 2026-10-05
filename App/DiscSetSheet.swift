import ISOBuilder
import SwiftUI

/// Plans a set of discs for files that don't fit on one (decision D16): pick a disc size, see
/// what goes on each disc, then burn them one at a time.
struct DiscSetSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var size: DiscSize
    @State private var plan: DiscSetPlan?
    @State private var problem: String?
    @State private var planning = false

    init(model: AppModel) {
        self.model = model
        _size = State(initialValue: model.defaultDiscSize)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Split Across Discs")
                .font(.title2.weight(.semibold))
            Text("Every disc but the last is filled to the last block. The file at each disc's edge is cut into parts that join back up, and each disc can be read, checked and restored on its own.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Form {
                TextField("Set name", text: $model.discName, prompt: Text("Name the set"))
                Picker("Disc size", selection: $size) {
                    ForEach(model.discSizeChoices) { choice in
                        Text(choice.name).tag(choice)
                    }
                }
            }
            .formStyle(.columns)

            planView
                .frame(minHeight: 240, alignment: .top)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Use This Plan") { Task { await use() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(plan == nil || planning || model.discName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 600)
        .task(id: size) { await makePlan() }
    }

    @ViewBuilder
    private var planView: some View {
        if planning {
            ProgressView("Working out what goes on each disc…")
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if let problem {
            Label(problem, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        } else if let plan {
            VStack(alignment: .leading, spacing: 8) {
                Text(summary(plan))
                    .fixedSize(horizontal: false, vertical: true)
                List(plan.discs, id: \.number) { disc in
                    DiscPlanRow(plan: plan, disc: disc)
                }
                .listStyle(.bordered)
                .alternatingRowBackgrounds()
            }
        }
    }

    private func summary(_ plan: DiscSetPlan) -> String {
        let count = plan.discs.count
        guard let last = plan.discs.last else { return "" }
        let lastSize = ByteCountFormatter.string(fromByteCount: last.bytes, countStyle: .file)
        var text = String(localized: "\(count) discs. The last holds \(lastSize)")
        if let fits = plan.lastDiscSize {
            text += String(localized: ", so a \(fits.name) is enough for it.")
        } else {
            text += "."
        }
        if plan.recoveryPercent > 0 {
            text += " " + String(localized: "Each disc carries its own checksums and \(plan.recoveryPercent)% recovery data.")
        }
        return text
    }

    private func makePlan() async {
        planning = true
        problem = nil
        defer { planning = false }
        do {
            plan = try await model.planDiscSet(size: size)
        } catch {
            plan = nil
            problem = "\(error)"
        }
    }

    /// Plans again first if the name changed, since each disc's name and set.json carry it.
    private func use() async {
        guard var chosen = plan else { return }
        if chosen.name != model.discName {
            planning = true
            defer { planning = false }
            do {
                chosen = try await model.planDiscSet(size: size)
            } catch {
                problem = "\(error)"
                return
            }
        }
        model.startDiscSet(chosen)
        dismiss()
    }
}

/// One disc of a plan: its size and what's on it, from first to last.
private struct DiscPlanRow: View {
    let plan: DiscSetPlan
    let disc: DiscSetPlan.Disc

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Disc \(disc.number)")
                    .font(.headline)
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: disc.bytes, countStyle: .file))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Text(contents)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .padding(.vertical, 2)
    }

    private var contents: String {
        let files = disc.pieces.filter { !$0.isDirectory }
        guard let first = files.first, let last = files.last else { return "" }
        if files.count == 1 { return describe(first) }
        return String(localized: "\(describe(first)) to \(describe(last)), \(files.count) files")
    }

    private func describe(_ piece: DiscSetPlan.Piece) -> String {
        guard let part = piece.part else { return piece.path }
        return String(localized: "\(piece.path) (part \(part))")
    }
}

/// Shown under the files while a set is being burned: which disc is next.
struct DiscSetBanner: View {
    let set: DiscSetPlan
    let disc: DiscSetPlan.Disc
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.stack.3d.up")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Disc \(disc.number) of \(set.discs.count): “\(set.volumeName(forDisc: disc.number))”")
                    .font(.callout.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Stop Set", action: cancel)
                .help("Forget the plan. Discs already burned are complete and can be restored.")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.4))
    }

    private var detail: String {
        let size = ByteCountFormatter.string(fromByteCount: disc.bytes, countStyle: .file)
        if disc.number == set.discs.count, let fits = set.lastDiscSize {
            return String(localized: "\(size). The last disc: a \(fits.name) or bigger.")
        }
        return String(localized: "\(size), on a \(set.discSize.name).")
    }
}
