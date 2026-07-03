import AppKit
import ClaudeManagerCore
import SwiftUI

/// A WYSIWYG launcher-icon preview: the real app icon with the badge composited by
/// the *authoritative* core renderer (the same path the saved `.icns` uses),
/// honoring the global `BadgeStyle`. Rendered off-main and re-run via `task(id:)`
/// whenever the inputs change; shows a placeholder while loading or if the real app
/// is missing.
struct BadgePreview: View {
    @EnvironmentObject private var model: AppModel
    let label: String
    let color: BadgeColor
    var size: CGFloat = 96

    @State private var image: NSImage?

    /// Everything that changes the rendered pixels — drives the async re-render.
    /// Includes the real app's icon URL so re-detecting Claude.app (Retry) refreshes
    /// the preview instead of leaving a stale placeholder.
    private struct Inputs: Equatable {
        let label: String
        let color: BadgeColor
        let style: BadgeStyle
        let pixels: Int
        let iconURL: URL?
    }

    private var inputs: Inputs {
        Inputs(
            label: label, color: color, style: model.badgeStyle,
            pixels: Int(size * 2), iconURL: model.realClaude?.iconURL
        )
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                    .fill(.quaternary)
                    .overlay(Image(systemName: "app.dashed").font(.system(size: size * 0.4))
                        .foregroundStyle(.secondary))
            }
        }
        .frame(width: size, height: size)
        .task(id: inputs) {
            image = await model.badgePreview(
                label: label, color: color, style: model.badgeStyle, pixels: Int(size * 2)
            )
        }
    }
}

/// A lightweight, synchronous pill used in list rows and the menu bar — an
/// approximation, not the authoritative render. It still honors the global style's
/// text rules (uppercase / max length) and weight so a row's label matches its icon.
struct BadgeChip: View {
    let label: String
    let color: BadgeColor
    var height: CGFloat = 22
    var style: BadgeStyle = .default

    private var text: String {
        let drawn = style.drawnLabel(from: label)
        return drawn.isEmpty ? " " : drawn
    }

    private var weight: Font.Weight {
        switch style.fontWeight {
        case .light: .light
        case .regular: .regular
        case .medium: .medium
        case .bold: .bold
        }
    }

    var body: some View {
        Text(text)
            .font(.system(size: height * 0.52, weight: weight))
            .foregroundStyle(.white)
            .padding(.horizontal, height * 0.28)
            .frame(minWidth: height, minHeight: height)
            .background(Capsule().fill(color.swiftUIColor))
            .overlay(Capsule().strokeBorder(
                .white.opacity(0.9),
                lineWidth: style.ringWidth > 0 ? max(1, height * 0.06) : 0
            ))
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
