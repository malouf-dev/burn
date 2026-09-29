import SwiftUI

@main
struct BurnApp: App {
    /// Launch with `-demo` to use a simulated drive with a blank DVD+R.
    @State private var model = AppModel(demo: CommandLine.arguments.contains("-demo"))

    var body: some Scene {
        Window("Burn", id: "main") {
            ContentView(model: model)
        }
        .windowResizability(.contentMinSize)
    }
}
