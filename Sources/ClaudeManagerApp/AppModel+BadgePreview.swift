import AppKit
import ClaudeManagerCore

// MARK: - Badge preview (WYSIWYG icon rendering)

extension AppModel {
    /// Render a WYSIWYG badge preview using the authoritative core renderer (same path
    /// the `.icns` uses). `nil` if the real app is absent. The heavy CoreGraphics work
    /// runs off the main actor; the `NSImage` is built back on the main actor.
    func badgePreview(
        label: String,
        color: BadgeColor,
        style: BadgeStyle,
        pixels: Int = 128
    ) async -> NSImage? {
        guard let iconURL = realClaude?.iconURL else { return nil }
        // Debounce in the caller's cancellable `.task`: a superseded preview (rapid
        // slider scrubbing) cancels this sleep before the render is even started.
        try? await Task.sleep(for: .milliseconds(80))
        if Task.isCancelled { return nil }
        let png = await Task.detached(priority: .userInitiated) {
            Self.renderBadgePNG(iconURL: iconURL, label: label, color: color, style: style, pixels: pixels)
        }.value
        // Back on the main actor here — build the AppKit image on the main thread.
        return png.flatMap(NSImage.init(data:))
    }

    /// Pure, actor-independent PNG render used by `badgePreview` off the main actor.
    private nonisolated static func renderBadgePNG(
        iconURL: URL,
        label: String,
        color: BadgeColor,
        style: BadgeStyle,
        pixels: Int
    ) -> Data? {
        guard let base = try? RealIconExtractor.loadBaseIcon(from: iconURL) else { return nil }
        return try? BadgeRenderer().renderPreviewPNG(
            base: base, label: label, color: color.rgba, style: style, pixels: pixels
        )
    }

    // MARK: - The global style, persisted

    /// Read the stored `BadgeStyle`, falling back to the default on anything unreadable — a
    /// preference that will not decode is not worth failing a launch over.
    ///
    /// Here rather than beside the property it initializes: `AppModel` sits on the enforced
    /// 500-line cap, and this is the file that already owns what a badge looks like.
    static func loadBadgeStyle(from defaults: UserDefaults) -> BadgeStyle {
        guard let data = defaults.data(forKey: PreferenceKeys.badgeStyle),
              let style = try? JSONDecoder().decode(BadgeStyle.self, from: data)
        else { return .default }
        return style
    }

    func persistBadgeStyle() {
        guard let data = try? JSONEncoder().encode(badgeStyle) else { return }
        defaults.set(data, forKey: PreferenceKeys.badgeStyle)
    }
}
