import AppKit
import ClaudeManagerCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

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

            Section {
                Toggle("Measure profile disk sizes (slower)", isOn: $model.measureSizes)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 440)
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
