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
            if let staged = model.stagedUpdate {
                if model.isApplyingStagedUpdate {
                    // A disabled Button, not a bare Label: an item with no action can still
                    // look selectable in a menu, so mark it clearly non-interactive.
                    Button {} label: {
                        Label(
                            "Applying Claude \(staged.stagedVersion)…",
                            systemImage: "arrow.down.circle.fill"
                        )
                    }
                    .disabled(true)
                } else {
                    // A submenu, not a one-click button: applying quits and relaunches every
                    // open profile (interrupting live sessions), so it must never fire from a
                    // single click. Opening the submenu and clicking the explicit item is the
                    // menu-bar's confirmation (a `.confirmationDialog` can't present from a menu).
                    Menu {
                        Button("Quit & Update All Profiles") {
                            Task { await model.applyStagedUpdate() }
                        }
                    } label: {
                        Label(
                            "Apply Claude \(staged.stagedVersion) to all profiles…",
                            systemImage: "arrow.down.circle.fill"
                        )
                    }
                }
                Divider()
            }

            // Profiles — the default profile first, then each clone, as one uniform list.
            // The default keeps its own person glyph (filled when running, mirroring the
            // clones' filled/empty circle) so it reads as a peer, not a special case.
            Button {
                Task { await model.openReal() }
            } label: {
                Label(
                    "Default profile\(model.primaryProfile?.isRunning == true ? " — running" : "")",
                    systemImage: model.primaryProfile?.isRunning == true
                        ? "person.crop.circle.fill" : "person.crop.circle"
                )
            }
            .disabled(model.isApplyingStagedUpdate)

            if model.profiles.isEmpty {
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
                    .disabled(model.isApplyingStagedUpdate)
                }
            }

            // Stop — every running profile, the default profile included.
            let runningClones = model.profiles.filter(\.isRunning)
            let defaultRunning = model.primaryProfile?.isRunning == true
            if defaultRunning || !runningClones.isEmpty {
                Divider()
                Menu("Stop") {
                    if defaultRunning {
                        Button("Default profile") {
                            Task { await model.stopDefaultProfile(force: false) }
                        }
                    }
                    ForEach(runningClones) { managed in
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
