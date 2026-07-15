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
        } else {
            // The primary (default-account) Claude — launched separately from any
            // launcher. Reliable even while clones run, unlike the raw Dock icon.
            Button {
                Task { await model.openReal() }
            } label: {
                Label("Open Claude (default account)", systemImage: "person.crop.circle")
            }
            .disabled(model.isApplyingStagedUpdate)

            if let staged = model.stagedUpdate {
                Button {
                    Task { await model.applyStagedUpdate() }
                } label: {
                    Label(
                        model.isApplyingStagedUpdate
                            ? "Applying Claude \(staged.stagedVersion)…"
                            : "Apply Claude \(staged.stagedVersion) to all accounts",
                        systemImage: "arrow.down.circle.fill"
                    )
                }
                .disabled(model.isApplyingStagedUpdate)
            }

            if model.profiles.isEmpty {
                Text("No launchers yet")
            } else {
                Divider()
                ForEach(model.profiles) { managed in
                    Button {
                        Task { await model.open(managed.profile) }
                    } label: {
                        Label(
                            "\(managed.profile.displayName)\(managed.isRunning ? " — running" : "")",
                            systemImage: managed.isRunning ? "circle.fill" : "circle"
                        )
                    }
                    .disabled(model.isApplyingStagedUpdate)
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
                            Button(
                                "\(managed.profile.displayName) — v\(managed.availableClaudeVersion ?? "")"
                            ) {
                                Task { await model.restart(managed.profile) }
                            }
                        }
                    }
                    .disabled(model.isApplyingStagedUpdate)
                }
            }
        }

        Divider()
        Button("Open Claude Manager") {
            openWindow(id: WindowID.main)
            // Forceful on purpose: this fires from the menu-bar extra while another app is
            // frontmost, where cooperative `NSApp.activate()` may leave the window behind it.
            // Warning-free on current SDKs (Apple softened the deprecation to a future
            // placeholder) — see #31 for why this isn't migrated to `activate()`.
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Refresh") { Task { await model.refresh() } }
        CheckForUpdatesView(updater: updater)
        Divider()
        Button("Quit Claude Manager") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
