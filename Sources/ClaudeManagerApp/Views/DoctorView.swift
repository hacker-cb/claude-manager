import ClaudeManagerCore
import SwiftUI

struct DoctorView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Doctor", systemImage: "stethoscope").font(.title3).bold()
                Spacer()
                summaryBadge
            }
            .padding()
            Divider()

            if model.diagnostics.isEmpty {
                ProgressView("Running checks…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.diagnostics) { diagnostic in
                    DiagnosticRow(diagnostic: diagnostic)
                }
            }

            Divider()
            HStack {
                Button("Rerun") { Task { await model.runDoctor() } }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 560, height: 460)
        .task { await model.runDoctor() }
    }

    @ViewBuilder private var summaryBadge: some View {
        if model.diagnostics.isEmpty {
            EmptyView()
        } else if !model.diagnostics.allHealthy {
            Label("Issues found", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
        } else if model.diagnostics.hasWarnings {
            Label("Warnings", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        } else {
            Label("All good", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
        }
    }
}

struct DiagnosticRow: View {
    let diagnostic: Diagnostic

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(diagnostic.title)
                if let detail = diagnostic.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var symbol: String {
        switch diagnostic.severity {
        case .ok: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    private var tint: Color {
        switch diagnostic.severity {
        case .ok: .green
        case .warning: .orange
        case .error: .red
        }
    }
}
