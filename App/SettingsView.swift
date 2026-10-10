import SwiftUI

/// Burn's Settings window.
struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Picker("Write speed", selection: $model.speedDefault) {
                Text("Slowest").tag(AppModel.SpeedDefault.slowest)
                Text("Fastest").tag(AppModel.SpeedDefault.fastest)
            }
            Text("The slowest or fastest speed the drive offers for each disc. A speed picked in the Burn sheet is kept for that kind of disc instead. Slower burns are less likely to fail.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .formStyle(.columns)
        .padding(20)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}
