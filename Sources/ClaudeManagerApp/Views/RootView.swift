import ClaudeManagerCore
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var launchAtLogin: LaunchAtLogin
    /// The window opens on the Limits page — it is the question asked before any particular
    /// profile is the answer, and the reason the window gets opened at all most days.
    @State private var selection: ProfileEntry.ID? = ProfileEntry.limitsID
    @State private var editor: EditorRoute?
    @State private var showDoctor = false
    /// Measured height of the app-global banner strip, used to reserve matching top space in the
    /// sidebar's `List` (see `body`). Zero when no banner is showing.
    @State private var bannerHeight: CGFloat = 0
    /// The alert heading, held here rather than read off `model.currentError` at render time.
    /// The message survives dismissal because `presenting:` hands the closure a captured
    /// payload; the title is an ordinary argument and has no such protection, so reading the
    /// published value directly would drop it to the default the moment OK clears it — leaving
    /// a "your data was kept" sentence under "Something went wrong" for the closing frames,
    /// which is the exact pairing `AppError.title` exists to prevent.
    @State private var alertTitle = AppError.defaultTitle

    var body: some View {
        // App-global banners (missing-Claude, Dock-refresh) are a full-width strip at the top of
        // the window. A Claude update is *not* one of them any more: it is the toolbar's
        // `ClaudeUpdateStatusButton`, because an offer that stands for days must not spend a strip
        // of every page for as long as it stands, and a strip is cut in two by the sidebar divider
        // — sentence in one column, button in the other.
        // Getting the strip right on macOS took two tries — both single-structure approaches
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
            // Every appearance, not only the first — and the `@State` default above does *not*
            // already cover it. This is a `Window` scene, not a `WindowGroup`: the scene is a
            // singleton whose state survives its window being closed, so a window closed on a
            // profile and reopened later comes back where it was left rather than on the page it
            // is meant to open on.
            //
            // What it rests on, stated rather than asserted away: `.task` restarts whenever the
            // view leaves and re-enters the hierarchy, which for this scene means the window
            // closing and reopening — not anything a person does inside an open one. Should
            // SwiftUI ever tear the split view down and rebuild it mid-session, the cost is a
            // sidebar selection snapping back to Limits; nothing is lost and the next click
            // undoes it.
            selection = ProfileEntry.limitsID
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
        // The heading comes from the message, not from this call site: the same channel
        // carries outcomes that are not failures (see `AppError`).
        .alert(
            alertTitle,
            isPresented: errorBinding,
            presenting: model.currentError
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { error in
            Text(error.message)
        }
        // Latch the heading while there is one to latch. Keyed on `id`, which is fresh per
        // message, so two alerts carrying the same text still re-arm it. `initial: true`
        // because a menu-bar action (Stop, Restart, Apply update) can set the message with no
        // window open at all — opening one then finds `currentError` already non-nil, and a
        // change-only observer never fires for it.
        .onChange(of: model.currentError?.id, initial: true) {
            if let title = model.currentError?.title { alertTitle = title }
        }
    }

    /// The full-width banner strip, with its height reported up via `BannerHeightKey` so the
    /// sidebar can reserve matching space. Always rendered (0-height when neither banner shows) so
    /// the measurement collapses cleanly back to zero once a banner clears.
    ///
    /// Two rows only, and both are short-lived: Claude is missing (the app cannot work at all
    /// until it is found) and pinned Dock tiles need a refresh (dismissible). A standing offer
    /// belongs in the toolbar, not here.
    private var banners: some View {
        let showing = model.realClaude == nil || model.dockRefreshPending
        return VStack(spacing: 0) {
            if model.realClaude == nil {
                missingClaudeBanner
            }
            if model.dockRefreshPending {
                dockRefreshBanner
            }
            if showing { Divider() }
        }
        // Two layers under the rows' own tints, and the second is the one that does the work.
        // A `.safeAreaInset` is a *content inset* for the `ScrollView` beneath it, not a margin:
        // the detail page scrolls under this strip, and a row whose only background is a
        // 12%-alpha tint lets that page show through — text over text. `.bar` alone does not
        // fix it either: a material blurs what is behind it, so a contrasty heading still comes
        // through as a coloured smear. The opaque window colour beneath is what makes the strip
        // a surface, and the divider is what closes it off.
        .background(.bar)
        .background(Color(nsColor: .windowBackgroundColor))
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: BannerHeightKey.self, value: proxy.size.height)
            }
        )
    }

    /// Shown after a rebuild/edit changed a launcher's icon. A pinned Dock tile keeps the
    /// old icon until the Dock is refreshed; the button does that now at the cost of one
    /// screen flash (restarting the Dock, and the icon-rendering agent behind it, is the
    /// only reliable way — there is no documented per-tile refresh). Dismiss leaves the
    /// tiles on their old icon, which is what the wording has to say: promising they heal
    /// on next open is how a user ends up staring at an icon that never changes.
    private var dockRefreshBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill").foregroundStyle(.blue)
            Text("Launcher icons updated — pinned Dock tiles keep the old icon until the Dock is refreshed.")
                .font(.callout)
            Spacer()
            Button("Refresh Dock now") { Task { await model.refreshDock() } }
                .help("Restarts the Dock so pinned icons update now — the screen briefly flashes")
            Button { model.dismissDockRefresh() } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Dismiss")
            .help("Dismiss — pinned tiles keep the old icon until you refresh the Dock")
        }
        .padding(8)
        .background(.blue.opacity(0.12))
    }

    @ViewBuilder private var detail: some View {
        // Gate on `realClaude` too (mirrors `profileEntries`): if Claude vanished while the default
        // row was selected, the row is gone from the sidebar, so fall through to the empty
        // state rather than stranding a hollow default-profile pane.
        if selection == ProfileEntry.limitsID {
            LimitsView()
        } else if selection == ProfileEntry.primaryID, model.realClaude != nil {
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
        // Left out entirely when there is nothing to say, rather than parked as a permanent
        // control for "no update" — `.idle` is the state the app is in almost all of the time.
        if model.claudeUpdateState != .idle {
            ToolbarItem { ClaudeUpdateStatusButton() }
        }
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
