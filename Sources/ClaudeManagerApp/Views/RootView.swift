import ClaudeManagerCore
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selection: ManagedProfile.ID?
    @State private var editor: EditorRoute?
    @State private var showDoctor = false

    var body: some View {
        NavigationSplitView {
            ProfileListView(selection: $selection)
                .navigationSplitViewColumnWidth(min: 240, ideal: 300)
        } detail: {
            detail
        }
        .toolbar { toolbar }
        .task { await model.refresh() }
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
        .safeAreaInset(edge: .top) {
            if model.realClaude == nil {
                missingClaudeBanner
            }
        }
    }

    @ViewBuilder private var detail: some View {
        if let id = selection, let managed = model.profiles.first(where: { $0.id == id }) {
            ProfileDetailView(managed: managed, editor: $editor)
                .id(managed.id)
        } else {
            ContentUnavailableView {
                Label("No profile selected", systemImage: "square.stack.3d.up")
            } description: {
                Text("Select a launcher on the left, or create one.")
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
            Button { Task { await model.refresh() } } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Rescan launchers and running state")
        }
        ToolbarItem {
            Button { showDoctor = true; Task { await model.runDoctor() } } label: {
                Label("Doctor", systemImage: "stethoscope")
            }
            .help("Run health checks")
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
            Button("Retry") { model.locate() }
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
