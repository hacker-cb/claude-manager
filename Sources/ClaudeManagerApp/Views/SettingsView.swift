import AppKit
import ClaudeManagerCore
import Sparkle
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showApply = false

    /// The app-scoped Sparkle updater (see ClaudeManagerApp) — shared, never re-created.
    let updater: SPUUpdater

    var body: some View {
        Form {
            Section("Real Claude") {
                LabeledContent(
                    "App",
                    value: model.realClaude.map { PathUtils.abbreviatingHome($0.appURL.path) } ?? "Not found"
                )
                LabeledContent("Version", value: model.realClaudeVersion ?? "—")
                Button("Re-detect") { model.locate() }
            }

            Section("Launcher install location") {
                Picker("Install launchers", selection: installSelection) {
                    Text("Next to Claude.app").tag(false)
                    Text("Custom folder").tag(true)
                }
                .pickerStyle(.radioGroup)

                if !model.installOverridePath.isEmpty {
                    HStack {
                        Text(PathUtils.abbreviatingHome(model.installOverridePath))
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Choose…") { chooseFolder { model.installOverridePath = $0.path } }
                    }
                }
                LabeledContent(
                    "Effective",
                    value: model.effectiveInstallDirectory.map { PathUtils.abbreviatingHome($0.path) } ?? "—"
                )
            }

            Section("New profile data") {
                HStack {
                    Text(PathUtils.abbreviatingHome(model.effectiveProfilesDirectory.path))
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Choose…") { chooseFolder { model.profilesOverridePath = $0.path } }
                    if !model.profilesOverridePath.isEmpty {
                        Button("Reset") { model.profilesOverridePath = "" }
                    }
                }
            }

            badgeSection

            Section("Updates") {
                UpdaterSettingsView(updater: updater)
            }

            Section {
                Toggle("Measure profile disk sizes (slower)", isOn: $model.measureSizes)
            }
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 620)
        .confirmationDialog(
            "Rebuild all launchers?",
            isPresented: $showApply,
            titleVisibility: .visible
        ) {
            Button("Rebuild \(model.profiles.count) launcher\(model.profiles.count == 1 ? "" : "s")") {
                Task { await model.rebuildAll() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Each launcher is regenerated with the current badge style and wrapper "
                    + "format (script, icon, Info.plist). Running launchers are skipped; "
                    + "the Dock refreshes for any that are rebuilt."
            )
        }
    }

    private var badgeSection: some View {
        Section("Badge style") {
            LabeledContent("Preview") {
                BadgePreview(label: "Work", color: .named("blue"), size: 88)
            }

            LabeledContent("Size") {
                Slider(value: $model.badgeStyle.scale, in: BadgeStyle.scaleRange)
            }
            Picker("Shape", selection: $model.badgeStyle.shape) {
                ForEach(BadgeStyle.Shape.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Picker("Corner", selection: $model.badgeStyle.corner) {
                ForEach(BadgeStyle.Corner.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Picker("Font weight", selection: $model.badgeStyle.fontWeight) {
                ForEach(BadgeStyle.FontWeight.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            LabeledContent("Ring") {
                Slider(value: $model.badgeStyle.ringWidth, in: BadgeStyle.ringRange)
            }
            Toggle("Uppercase label", isOn: $model.badgeStyle.uppercase)
            Stepper(
                "Max characters: \(model.badgeStyle.maxLabelLength)",
                value: $model.badgeStyle.maxLabelLength,
                in: BadgeStyle.labelLengthRange
            )

            HStack {
                Button("Reset to defaults") { model.badgeStyle = .default }
                    .disabled(model.badgeStyle == .default)
                Spacer()
                Button("Apply to all launchers") { showApply = true }
                    .disabled(model.realClaude == nil || model.isBusy || model.profiles.isEmpty)
            }
            Text("Editing updates newly created launchers. “Apply” rebuilds every existing launcher.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var installSelection: Binding<Bool> {
        Binding(
            get: { !model.installOverridePath.isEmpty },
            set: { custom in
                if custom {
                    chooseFolder { model.installOverridePath = $0.path }
                } else {
                    model.installOverridePath = ""
                }
            }
        )
    }

    private func chooseFolder(_ completion: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            completion(url)
        }
    }
}

// MARK: - Badge-style picker labels (UI strings kept out of the core model)

private extension BadgeStyle.Shape {
    var title: String {
        switch self {
        case .pill: "Pill"
        case .circle: "Circle"
        case .roundedSquare: "Rounded square"
        }
    }
}

private extension BadgeStyle.Corner {
    var title: String {
        switch self {
        case .bottomTrailing: "Bottom right"
        case .bottomLeading: "Bottom left"
        case .topTrailing: "Top right"
        case .topLeading: "Top left"
        }
    }
}

private extension BadgeStyle.FontWeight {
    var title: String {
        switch self {
        case .light: "Light"
        case .regular: "Regular"
        case .medium: "Medium"
        case .bold: "Bold"
        }
    }
}
