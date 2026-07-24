import AppKit
import SwiftUI

/// Read-only viewer for the latest raw `/usage` response per account — the escape hatch for
/// debugging a limit that renders oddly (e.g. a new `limits[]` kind the parser bucketed as
/// "other"). One account at a time via a picker, with a Copy button onto the general pasteboard.
struct UsageRawInspectorView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var entries: [AppModel.UsageInspectorEntry] = []
    @State private var loaded = false
    @State private var selection: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(width: 620, height: 520)
        .task {
            entries = await model.loadUsageInspectorEntries()
            selection = entries.first?.id
            loaded = true
        }
    }

    private var header: some View {
        HStack {
            Label("Usage response", systemImage: "curlybraces").font(.title3).bold()
            Spacer()
            if entries.count > 1 {
                Picker("Account", selection: $selection) {
                    ForEach(entries) { Text($0.name).tag($0.id as String?) }
                }
                .labelsHidden()
                .frame(maxWidth: 200)
            }
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding()
    }

    @ViewBuilder private var content: some View {
        if !loaded {
            ProgressView("Loading…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let entry = entries.first(where: { $0.id == selection }), let json = entry.rawJSON {
            jsonBody(name: entry.name, json: json)
        } else {
            ContentUnavailableView(
                "No stored response",
                systemImage: "tray",
                description: Text("No raw usage response has been captured yet. Refresh usage first.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func jsonBody(name: String, json: String) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(name).font(.headline)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(json, forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            Divider()
            ScrollView([.vertical, .horizontal]) {
                Text(json)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
