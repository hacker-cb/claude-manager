import AppKit
import ClaudeManagerCore
import Sparkle
import SwiftUI

struct MenuBarContent: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    /// The app-scoped Sparkle updater (see ClaudeManagerApp) — shared, never re-created.
    let updater: SPUUpdater

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

            let behind = model.profiles.filter(\.claudeUpdateAvailable)
            if !behind.isEmpty {
                Menu("Restart to Update") {
                    ForEach(behind) { managed in
                        Button("\(managed.profile.displayName) — v\(managed.availableClaudeVersion ?? "")") {
                            Task { await model.restart(managed.profile) }
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
        CheckForUpdatesView(updater: updater)
        Divider()
        Button("Quit Claude Manager") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
