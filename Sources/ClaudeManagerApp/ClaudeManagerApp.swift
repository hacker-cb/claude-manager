import SwiftUI

@main
struct ClaudeManagerApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("Claude Manager", id: WindowID.main) {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 760, minHeight: 480)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .toolbar) {
                Button("Refresh") { Task { await model.refresh() } }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }

        MenuBarExtra("Claude Manager", systemImage: "square.stack.3d.up.fill") {
            MenuBarContent()
                .environmentObject(model)
        }

        Settings {
            SettingsView()
                .environmentObject(model)
        }
    }
}

enum WindowID {
    static let main = "main"
}
