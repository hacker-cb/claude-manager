import ClaudeManagerCore
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var launchAtLogin: LaunchAtLogin
    @State private var selection: ProfileEntry.ID?
    @State private var editor: EditorRoute?
    @State private var showDoctor = false
    /// Drives the "apply staged update" confirmation. Window-local on purpose: only the
    /// banner button sets it and only SwiftUI resets it (on dismiss), so nothing external
    /// can toggle the binding while the dialog is up (a programmatic dismiss of a live
    /// `confirmationDialog` crashes AppKit's dialog bridge).
    @State private var confirmingStagedApply = false
    /// Measured height of the app-global banner strip, used to reserve matching top space in the
    /// sidebar's `List` (see `body`). Zero when no banner is showing.
    @State private var bannerHeight: CGFloat = 0

    var body: some View {
        // App-global banners (missing-Claude, staged-update) are a full-width strip at the top of
        // the window. Getting this right on macOS took two tries — both single-structure approaches
        // break one column:
        //   • `.safeAreaInset(.top)` on the split view (pre-#59): reserves space in the *detail*
        //     column but not in the sidebar's `List`, so the banner floats over the first row.
        //   • wrapping the split view in a `VStack` below the banner (#59): the sidebar is fine, but
        //     the detail column's material underlaps the window toolbar and, on the first layout
        //     with a banner already present, bleeds *up* over the banner as a white plate (only a
        //     sidebar toggle — i.e. a relayout — cleared it).
        // So use both: keep the split view as the window root (detail material stays correct) and
        // hang the full-width banner off a split-view `.safeAreaInset`, then reserve the same space
        // in the sidebar `List` explicitly via `bannerHeight` (which the inset doesn't propagate to).
        NavigationSplitView {
            ProfileListView(selection: $selection)
                .navigationSplitViewColumnWidth(min: 240, ideal: 300)
                // The split-view-level banner inset below doesn't reach the sidebar's `List`, so its
                // first row would sit under the banner — reserve the measured banner height here.
                .safeAreaInset(edge: .top, spacing: 0) {
                    Color.clear.frame(height: bannerHeight)
                }
        } detail: {
            detail
        }
        .safeAreaInset(edge: .top, spacing: 0) { banners }
        .onPreferenceChange(BannerHeightKey.self) { bannerHeight = $0 }
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
                .environmentObject(launchAtLogin)
        }
        .modifier(DeepLinkResidencyNudge())
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
            model.stagedUpdate.map { "Apply Claude \($0.stagedVersion) to all profiles?" }
                ?? "Apply the staged Claude update?",
            isPresented: $confirmingStagedApply,
            titleVisibility: .visible
        ) {
            Button("Quit & Update All Profiles") {
                Task { await model.applyStagedUpdate() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Every open profile is quit and reopened to install the update — "
                    + "any active session is interrupted, so save your work first."
            )
        }
    }

    /// The full-width banner strip, with its height reported up via `BannerHeightKey` so the
    /// sidebar can reserve matching space. Always rendered (0-height when neither banner shows) so
    /// the measurement collapses cleanly back to zero once a banner clears.
    private var banners: some View {
        VStack(spacing: 0) {
            if model.realClaude == nil {
                missingClaudeBanner
            }
            if let staged = model.stagedUpdate {
                stagedUpdateBanner(staged)
            }
        }
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: BannerHeightKey.self, value: proxy.size.height)
            }
        )
    }

    private func stagedUpdateBanner(_ staged: StagedUpdate) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(.blue)
            Text("Claude \(staged.stagedVersion) is downloaded but not applied — open profiles block it.")
                .font(.callout)
            Spacer()
            Button(model.isApplyingStagedUpdate ? "Applying…" : "Apply to all profiles") {
                confirmingStagedApply = true
            }
            .disabled(model.isApplyingStagedUpdate)
        }
        .padding(8)
        .background(.blue.opacity(0.12))
    }

    @ViewBuilder private var detail: some View {
        // Gate on `realClaude` too (mirrors `profileEntries`): if Claude vanished while the default
        // row was selected, the row is gone from the sidebar, so fall through to the empty
        // state rather than stranding a hollow default-profile pane.
        if selection == ProfileEntry.primaryID, model.realClaude != nil {
            PrimaryProfileDetailView()
        } else if let id = selection, let managed = model.profiles.first(where: { $0.id == id }) {
            ProfileDetailView(managed: managed, editor: $editor)
                .id(managed.id)
        } else {
            ContentUnavailableView {
                Label("No profile selected", systemImage: "square.stack.3d.up")
            } description: {
                Text("Select a profile on the left, or create a launcher.")
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
        // No dedicated "Open Claude" toolbar button: the default profile is now the first
        // sidebar row and is opened like any other profile (select → Open, or right-click →
        // Open), with the menu-bar extra's "Default profile" item as the windowless quick
        // launch. A per-profile toolbar shortcut only for the default broke that symmetry.
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

/// Carries the measured banner-strip height up the view tree so the sidebar `List` can reserve
/// matching top space (a split-view-level `.safeAreaInset` doesn't reach the sidebar on macOS).
private struct BannerHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
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
