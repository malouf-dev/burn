import SwiftUI

@main
struct BurnApp: App {
    /// Launch with `-demo` to use a simulated drive with a blank DVD+R.
    @State private var model = AppModel(demo: CommandLine.arguments.contains("-demo"))
    @State private var verifier = VerifyModel()
    @State private var restorer = RestoreModel()

    var body: some Scene {
        Window("Burn", id: "main") {
            ContentView(model: model, verifier: verifier, restorer: restorer)
        }
        .defaultSize(width: 820, height: 620)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView(model: model)
        }
    }
}
