import SwiftUI

/// Picks which Claude profile should receive an inbound `claude://` link. The URL carries
/// no profile identity, so this choice can't be automated.
struct DeepLinkPickerView: View {
    let url: URL
    let targets: [DeepLinkTarget]
    let onPick: (DeepLinkTarget) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Open this link in which profile?")
                .font(.headline)
            Text(url.absoluteString)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .textSelection(.enabled)
            Divider()
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(targets) { target in
                        targetButton(target)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(width: 420, height: 380)
    }

    private func targetButton(_ target: DeepLinkTarget) -> some View {
        Button { onPick(target) } label: {
            HStack {
                Image(systemName: icon(for: target))
                Text(target.displayName)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
    }

    private func icon(for target: DeepLinkTarget) -> String {
        if case .defaultProfile = target { return "person.crop.circle" }
        return "square.stack.3d.up"
    }
}
