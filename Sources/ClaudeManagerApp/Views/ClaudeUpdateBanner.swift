import ClaudeManagerCore
import SwiftUI

/// The one place a Claude update is offered, in the window.
///
/// Deliberately not a notification and not a nightly job: installing closes every profile the
/// user has open, so it happens when they say so and while they are looking at it. Downloading
/// and verifying happen on their own beforehand, which is why the button is usually an instant
/// action rather than a wait.
struct ClaudeUpdateBanner: View {
    @EnvironmentObject private var model: AppModel
    @State private var confirming = false

    var body: some View {
        switch model.claudeUpdateState {
        case .idle:
            EmptyView()
        case let .available(update):
            // Reached both before a download starts *and* after one is interrupted — a slept
            // laptop, a dropped connection — so it must not claim to be downloading. It is
            // not necessarily brief either: the resume waits for the next scheduled check,
            // which is why there is a button to ask for it now.
            banner(icon: "arrow.down.circle") {
                Text("Claude \(update.version) is available.")
            } trailing: {
                Button("Download") { model.checkForClaudeUpdateNow() }
            }
        case let .downloading(version, received, total):
            banner(icon: "arrow.down.circle") {
                HStack(spacing: 8) {
                    Text("Downloading Claude \(version)…")
                    if let total, total > 0 {
                        ProgressView(value: Double(received), total: Double(total))
                            .progressViewStyle(.linear)
                            .frame(width: 120)
                        Text(Self.progressText(received: received, total: total))
                            .monospacedDigit()
                    }
                }
            }
        case let .ready(verified):
            banner(icon: "arrow.down.circle.fill") {
                Text("Claude \(verified.version) is ready to install.")
            } trailing: {
                // Confirmed, because pressing it closes every open profile. The dialog is
                // attached to the button rather than the row so it survives the row being
                // replaced while it is up.
                Button("Install…") { confirming = true }
                    .confirmationDialog(
                        "Install Claude \(verified.version)?",
                        isPresented: $confirming,
                        titleVisibility: .visible
                    ) {
                        Button("Close profiles and install") {
                            Task { await model.installClaudeUpdate() }
                        }
                        Button("Not now", role: .cancel) {}
                    } message: {
                        Text(
                            "Every open profile will be closed and reopened. A profile with a "
                                + "session still working will refuse to close, and the installed "
                                + "app will be left as it is."
                        )
                    }
            }
        case let .installing(version):
            banner(icon: "arrow.down.circle.fill") {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Installing Claude \(version)…")
                }
            }
        case let .failed(reason):
            banner(icon: "exclamationmark.triangle.fill", tint: .orange) {
                Text(reason)
            } trailing: {
                // Through the same entry point as every other trigger, so repeated clicks
                // cannot start a second check beside the first — and so a retry that fails
                // again says so, rather than clearing the banner and looking like a success.
                Button("Try again") { model.checkForClaudeUpdateNow() }
            }
        }
    }

    private func banner(
        icon: String,
        tint: Color = .secondary,
        @ViewBuilder content: () -> some View,
        @ViewBuilder trailing: () -> some View = { EmptyView() }
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint)
            content()
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            trailing()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.4))
    }

    /// `142 MB of 335 MB`, formatted the way the Finder would.
    ///
    /// The formatter is built once: progress arrives many times a second during a 335 MB
    /// transfer, and each one re-renders this view.
    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    static func progressText(received: Int64, total: Int64) -> String {
        let format = byteFormatter
        return "\(format.string(fromByteCount: received)) of \(format.string(fromByteCount: total))"
    }
}
