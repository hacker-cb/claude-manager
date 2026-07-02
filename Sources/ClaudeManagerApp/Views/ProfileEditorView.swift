import ClaudeManagerCore
import SwiftUI

struct ProfileEditorView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let route: EditorRoute

    @State private var name: String
    @State private var displayName: String
    @State private var label: String
    @State private var bundleID: String
    @State private var profilePath: String
    @State private var badge: BadgeColor
    @State private var customColor: Color
    @State private var force = false
    @State private var showAdvanced = false
    @State private var saving = false

    private let original: Profile?

    init(route: EditorRoute) {
        self.route = route
        switch route {
        case .add:
            original = nil
            _name = State(initialValue: "")
            _displayName = State(initialValue: "")
            _label = State(initialValue: "")
            _bundleID = State(initialValue: "")
            _profilePath = State(initialValue: "")
            _badge = State(initialValue: .named("blue"))
            _customColor = State(initialValue: BadgeColor.named("blue").swiftUIColor)
        case let .edit(profile):
            original = profile
            _name = State(initialValue: profile.name)
            _displayName = State(initialValue: profile.displayName)
            _label = State(initialValue: profile.label)
            _bundleID = State(initialValue: profile.bundleID)
            _profilePath = State(initialValue: profile.profilePath)
            _badge = State(initialValue: profile.color)
            _customColor = State(initialValue: profile.color.swiftUIColor)
        }
    }

    private var isEdit: Bool {
        original != nil
    }

    private var effectiveLabel: String {
        (label.isEmpty ? Profile.defaultLabel(for: name.isEmpty ? "?" : name) : label).uppercased()
    }

    private var nameIsValid: Bool {
        Profile.isValidName(name)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            form
            Divider()
            footer
        }
        .frame(width: 540)
        .frame(minHeight: 520)
    }

    private var header: some View {
        HStack(spacing: 16) {
            BadgePreview(baseIcon: model.realAppIcon, label: effectiveLabel, color: badge, size: 72)
            VStack(alignment: .leading, spacing: 4) {
                Text(isEdit ? "Edit Profile" : "New Profile").font(.title3).bold()
                Text(isEdit ? "Rebuilds the launcher with your changes." :
                    "Creates a thin launcher and an isolated profile.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(20)
    }

    private var form: some View {
        Form {
            if !isEdit {
                TextField("Name", text: $name, prompt: Text("work"))
                    .help("Short handle, e.g. work. Letters, digits, dashes, underscores.")
                if !name.isEmpty, !nameIsValid {
                    Label(
                        "Use letters, digits, dashes, or underscores.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption).foregroundStyle(.orange)
                }
            } else {
                LabeledContent("Name", value: name)
            }

            TextField(
                "Badge label",
                text: $label,
                prompt: Text(Profile.defaultLabel(for: name.isEmpty ? "?" : name))
            )
            .help("Text drawn on the badge. Defaults to the first two letters of the name.")

            colorPicker

            TextField(
                "Display name",
                text: $displayName,
                prompt: Text(Profile.defaultDisplayName(for: name.isEmpty ? "NAME" : name))
            )
            .help("The app name shown in the Dock and Finder.")

            DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                TextField(
                    "Bundle identifier",
                    text: $bundleID,
                    prompt: Text(Profile.defaultBundleID(for: name.isEmpty ? "name" : name))
                )
                if isEdit {
                    LabeledContent("Profile data", value: PathUtils.abbreviatingHome(profilePath))
                } else {
                    TextField(
                        "Profile data dir",
                        text: $profilePath,
                        prompt: Text(PathUtils
                            .abbreviatingHome(model.effectiveProfilesDirectory
                                .appendingPathComponent(name.isEmpty ? "name" : name.lowercased()).path))
                    )
                    Toggle("Rebuild if a launcher already exists (force)", isOn: $force)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var colorPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Badge color").font(.callout)
            HStack(spacing: 8) {
                ForEach(BadgeColor.paletteNames, id: \.self) { paletteName in
                    let color = BadgeColor.named(paletteName)
                    Circle()
                        .fill(color.swiftUIColor)
                        .frame(width: 22, height: 22)
                        .overlay(Circle().strokeBorder(
                            .primary.opacity(isSelected(paletteName) ? 0.9 : 0),
                            lineWidth: 2
                        ))
                        .onTapGesture { badge = color }
                        .help(paletteName.capitalized)
                }
                Divider().frame(height: 22)
                ColorPicker("Custom", selection: $customColor, supportsOpacity: false)
                    .labelsHidden()
                    .onChange(of: customColor) { _, newValue in
                        badge = .custom(RGBAColor(newValue))
                    }
            }
        }
    }

    private func isSelected(_ paletteName: String) -> Bool {
        if case let .named(current) = badge { return current == paletteName }
        return false
    }

    private var footer: some View {
        HStack {
            if saving { ProgressView().controlSize(.small) }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(isEdit ? "Save" : "Create") { Task { await save() } }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(saving || (!isEdit && !nameIsValid))
        }
        .padding(16)
    }

    private func save() async {
        saving = true
        defer { saving = false }
        if let original {
            guard let installDir = model.effectiveInstallDirectory else { return }
            var updated = original
            updated.displayName = displayName.isEmpty ? original.displayName : displayName
            updated.label = effectiveLabel
            updated.color = badge
            updated.bundleID = bundleID.isEmpty ? original.bundleID : bundleID
            updated.appPath = installDir.appendingPathComponent("\(updated.displayName).app").path
            if await model.updateProfile(original: original, to: updated) { dismiss() }
        } else {
            let request = AddProfileRequest(
                name: name,
                label: label.isEmpty ? nil : label,
                color: badge,
                displayName: displayName.isEmpty ? nil : displayName,
                bundleID: bundleID.isEmpty ? nil : bundleID,
                profilePath: profilePath.isEmpty ? nil : profilePath,
                force: force
            )
            if await model.addProfile(request) { dismiss() }
        }
    }
}
