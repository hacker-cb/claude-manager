import AppKit
import ClaudeManagerCore
import SwiftUI

struct MenuBarContent: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if model.realClaude == nil {
            Text("Claude.app not found")
        } else if model.profiles.isEmpty {
            Text("No launchers yet")
        } else {
            ForEach(model.profiles) { managed in
                Button {
                    Task { await model.open(managed.profile) }
                } label: {
                    Label(
                        "\(managed.profile.displayName)\(managed.isRunning ? " — running" : "")",
                        systemImage: managed.isRunning ? "circle.fill" : "circle"
                    )
                }
            }

            let running = model.profiles.filter(\.isRunning)
            if !running.isEmpty {
                Divider()
                Menu("Stop") {
                    ForEach(running) { managed in
                        Button(managed.profile.displayName) {
                            Task { await model.stop(managed.profile, force: false) }
                        }
                    }
                }
            }
        }

        Divider()
        Button("Open Claude Manager") {
            openWindow(id: WindowID.main)
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Refresh") { Task { await model.refresh() } }
        Divider()
        Button("Quit Claude Manager") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
