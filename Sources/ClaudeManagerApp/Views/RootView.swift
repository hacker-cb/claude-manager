import ClaudeManagerCore
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selection: Account.ID?
    @State private var editor: EditorRoute?
    @State private var showDoctor = false
    /// Drives the "apply staged update" confirmation. Window-local on purpose: only the
    /// banner button sets it and only SwiftUI resets it (on dismiss), so nothing external
    /// can toggle the binding while the dialog is up (a programmatic dismiss of a live
    /// `confirmationDialog` crashes AppKit's dialog bridge).
    @State private var confirmingStagedApply = false

    var body: some View {
        // App-global banners sit in their own full-width strip *above* the split view,
        // not as a `.safeAreaInset` on the `NavigationSplitView`: on macOS that inset
        // isn't propagated into the sidebar's `List`, so the banner floats over the
        // first row and the unified toolbar instead of reserving its own space.
        VStack(spacing: 0) {
            banners
            splitView
        }
    }

    @ViewBuilder private var banners: some View {
        if model.realClaude == nil {
            missingClaudeBanner
        }
        if let staged = model.stagedUpdate {
            stagedUpdateBanner(staged)
        }
    }

    private var splitView: some View {
        NavigationSplitView {
            ProfileListView(selection: $selection)
                .navigationSplitViewColumnWidth(min: 240, ideal: 300)
        } detail: {
            detail
        }
        .toolbar { toolbar }
        .task {
            // Idempotent — `init` also kicks this off window-independently (a login /
            // menu-bar-only launch shows no window, so this `.task` may not run).
            await model.performLaunchTasks()
            // Refresh on *every* appearance too: reopening the window after an external
            // change — while the app stayed active, so `didBecomeActive` never fired —
            // must show fresh state, not wait out the 60s poll. (Launch work above is
            // once-only; this refresh is not.)
            await model.refresh()
        }
        .sheet(item: $editor) { route in
            ProfileEditorView(route: route)
                .environmentObject(model)
        }
        .sheet(isPresented: $showDoctor) {
            DoctorView()
                .environmentObject(model)
        }
        .alert(
            "Something went wrong",
            isPresented: errorBinding,
            presenting: model.currentError
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { error in
            Text(error.message)
        }
        .confirmationDialog(
            model.stagedUpdate.map { "Apply Claude \($0.stagedVersion) to all accounts?" }
                ?? "Apply the staged Claude update?",
            isPresented: $confirmingStagedApply,
            titleVisibility: .visible
        ) {
            Button("Quit & Update All Accounts") {
                Task { await model.applyStagedUpdate() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Every open account is quit and reopened to install the update — "
                    + "any active session is interrupted, so save your work first."
            )
        }
    }

    private func stagedUpdateBanner(_ staged: StagedUpdate) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(.blue)
            Text("Claude \(staged.stagedVersion) is downloaded but not applied — open accounts block it.")
                .font(.callout)
            Spacer()
            Button(model.isApplyingStagedUpdate ? "Applying…" : "Apply to all accounts") {
                confirmingStagedApply = true
            }
            .disabled(model.isApplyingStagedUpdate)
        }
        .padding(8)
        .background(.blue.opacity(0.12))
    }

    @ViewBuilder private var detail: some View {
        // Gate on `realClaude` too (mirrors `accounts`): if Claude vanished while the default
        // row was selected, the row is gone from the sidebar, so fall through to the empty
        // state rather than stranding a hollow default-account pane.
        if selection == Account.primaryID, model.realClaude != nil {
            PrimaryAccountDetailView()
        } else if let id = selection, let managed = model.profiles.first(where: { $0.id == id }) {
            ProfileDetailView(managed: managed, editor: $editor)
                .id(managed.id)
        } else {
            ContentUnavailableView {
                Label("No account selected", systemImage: "square.stack.3d.up")
            } description: {
                Text("Select an account on the left, or create a launcher.")
            } actions: {
                Button("New Profile…") { editor = .add }
            }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button { editor = .add } label: { Label("New Profile", systemImage: "plus") }
                .help("Create a new launcher profile")
        }
        ToolbarItem {
            Button { Task { await model.openReal() } } label: {
                Label("Open Claude", systemImage: "person.crop.circle")
            }
            .help(
                "Launch or focus your primary Claude account (the default profile). "
                    + "Use this instead of the Dock icon while clones are running."
            )
            .disabled(model.realClaude == nil)
        }
        ToolbarItem {
            Button { Task { await model.refresh() } } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Rescan launchers and running state")
        }
        ToolbarItem {
            // DoctorView runs the checks in its own `.task`; just present it.
            Button { showDoctor = true } label: {
                Label("Doctor", systemImage: "stethoscope")
            }
            .help("Run health checks")
        }
        ToolbarItem {
            SettingsLink { Label("Settings", systemImage: "gearshape") }
                .help("Open settings")
        }
        if model.isBusy {
            ToolbarItem { ProgressView().controlSize(.small) }
        }
    }

    private var missingClaudeBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(model.locateError ?? "Real Claude.app was not found.")
                .font(.callout)
            Spacer()
            Button("Retry") { Task { await model.relocate() } }
        }
        .padding(8)
        .background(.orange.opacity(0.12))
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { model.currentError != nil },
            set: { if !$0 { model.currentError = nil } }
        )
    }
}

/// Which editor sheet to present.
enum EditorRoute: Identifiable {
    case add
    case edit(Profile)

    var id: String {
        switch self {
        case .add: "add"
        case let .edit(profile): "edit:\(profile.id)"
        }
    }
}
