import ClaudeManagerCore
import SwiftUI

/// A live SwiftUI approximation of the launcher icon: the real app icon with a
/// colored pill badge bottom-right. The authoritative `.icns` is rendered by the
/// core on save; this is just a fast, IO-free preview for the editor and detail.
struct BadgePreview: View {
    let baseIcon: NSImage?
    let label: String
    let color: BadgeColor
    var size: CGFloat = 96

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            base
                .frame(width: size, height: size)
            BadgeChip(label: label, color: color, height: size * 0.34)
                .padding(size * 0.055)
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder private var base: some View {
        if let baseIcon {
            Image(nsImage: baseIcon)
                .resizable()
                .interpolation(.high)
        } else {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(.quaternary)
                .overlay(Image(systemName: "app.dashed").font(.system(size: size * 0.4))
                    .foregroundStyle(.secondary))
        }
    }
}

/// Just the colored pill + label, reused in list rows and the menu bar.
struct BadgeChip: View {
    let label: String
    let color: BadgeColor
    var height: CGFloat = 22

    var body: some View {
        Text(label.isEmpty ? " " : label)
            .font(.system(size: height * 0.52, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, height * 0.28)
            .frame(minWidth: height, minHeight: height)
            .background(Capsule().fill(color.swiftUIColor))
            .overlay(Capsule().strokeBorder(.white.opacity(0.9), lineWidth: max(1, height * 0.06)))
            .fixedSize()
    }
}

/// Green/gray running indicator.
struct StatusDot: View {
    let isRunning: Bool
    var body: some View {
        Circle()
            .fill(isRunning ? Color.green : Color.secondary.opacity(0.4))
            .frame(width: 8, height: 8)
            .help(isRunning ? "Running" : "Stopped")
    }
}
