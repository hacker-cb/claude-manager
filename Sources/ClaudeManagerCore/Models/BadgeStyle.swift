import Foundation

/// Global, user-configurable geometry & typography for the launcher badge. Label
/// text and color stay per-profile (in the launcher marker); everything about the
/// badge's *shape* lives here and applies to every launcher uniformly.
///
/// `.default` reproduces the original hard-coded geometry, so an unconfigured
/// install renders the same badge — with one deliberate difference: the label is
/// now capped at `maxLabelLength` (default 3), which also bounds the pill width so a
/// long label can no longer overflow the icon. All ratios are a fraction of the
/// icon's width, matching `BadgeRenderer`'s coordinate space.
public struct BadgeStyle: Codable, Sendable, Equatable {
    /// Silhouette of the badge behind the label.
    public enum Shape: String, Codable, Sendable, CaseIterable {
        /// Stadium/pill that grows with the text (the original look).
        case pill
        /// Fixed square footprint with a full-radius corner — a true circle.
        case circle
        /// Grows with the text, but with a gently rounded corner instead of a pill.
        case roundedSquare
    }

    /// Which corner of the icon the badge sits in.
    public enum Corner: String, Codable, Sendable, CaseIterable {
        case bottomTrailing, bottomLeading, topTrailing, topLeading

        /// In `BadgeRenderer`'s bottom-left origin space: trailing = high x, top = high y.
        var isTrailing: Bool {
            self == .bottomTrailing || self == .topTrailing
        }

        var isTop: Bool {
            self == .topLeading || self == .topTrailing
        }
    }

    /// Font weight, mapped to a real Helvetica Neue face (no synthetic weights).
    public enum FontWeight: String, Codable, Sendable, CaseIterable {
        case light, regular, medium, bold

        /// The concrete PostScript face name. `.bold` is the original default.
        var fontName: String {
            switch self {
            case .light: "HelveticaNeue-Light"
            case .regular: "HelveticaNeue"
            case .medium: "HelveticaNeue-Medium"
            case .bold: "HelveticaNeue-Bold"
            }
        }
    }

    /// Badge height as a fraction of the icon width. Clamped to `scaleRange`.
    public var scale: Double
    public var shape: Shape
    public var corner: Corner
    /// White ring thickness as a fraction of the icon width; `0` disables the ring.
    /// Clamped to `ringRange`.
    public var ringWidth: Double
    public var fontWeight: FontWeight
    /// Uppercase the label before drawing.
    public var uppercase: Bool
    /// Drawn label is truncated to this many characters (kept ≥ 1). Bounds the pill
    /// width so a long label can never overflow the icon.
    public var maxLabelLength: Int

    public static let scaleRange: ClosedRange<Double> = 0.2 ... 0.45
    public static let ringRange: ClosedRange<Double> = 0 ... 0.04
    public static let labelLengthRange: ClosedRange<Int> = 1 ... 6

    /// The original hard-coded look: a bold pill in the bottom-right, 34% tall,
    /// with the classic white ring, uppercased, up to 3 characters.
    public static let `default` = BadgeStyle(
        scale: 0.34,
        shape: .pill,
        corner: .bottomTrailing,
        ringWidth: 0.018,
        fontWeight: .bold,
        uppercase: true,
        maxLabelLength: 3
    )

    public init(
        scale: Double = 0.34,
        shape: Shape = .pill,
        corner: Corner = .bottomTrailing,
        ringWidth: Double = 0.018,
        fontWeight: FontWeight = .bold,
        uppercase: Bool = true,
        maxLabelLength: Int = 3
    ) {
        self.scale = scale.clamped(to: Self.scaleRange)
        self.shape = shape
        self.corner = corner
        self.ringWidth = ringWidth.clamped(to: Self.ringRange)
        self.fontWeight = fontWeight
        self.uppercase = uppercase
        self.maxLabelLength = maxLabelLength.clamped(to: Self.labelLengthRange)
    }

    /// Decode leniently — a missing or out-of-range field falls back to the default
    /// and is re-clamped, so a stale/partial persisted blob can never yield an
    /// invalid style or a decode failure.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = BadgeStyle.default
        try self.init(
            scale: c.decodeIfPresent(Double.self, forKey: .scale) ?? d.scale,
            shape: c.decodeIfPresent(Shape.self, forKey: .shape) ?? d.shape,
            corner: c.decodeIfPresent(Corner.self, forKey: .corner) ?? d.corner,
            ringWidth: c.decodeIfPresent(Double.self, forKey: .ringWidth) ?? d.ringWidth,
            fontWeight: c.decodeIfPresent(FontWeight.self, forKey: .fontWeight) ?? d.fontWeight,
            uppercase: c.decodeIfPresent(Bool.self, forKey: .uppercase) ?? d.uppercase,
            maxLabelLength: c.decodeIfPresent(Int.self, forKey: .maxLabelLength) ?? d.maxLabelLength
        )
    }

    /// The label as it will actually be drawn: uppercased (if enabled) and truncated
    /// to `maxLabelLength`. The single choke point both the renderer and the UI use,
    /// so a badge and its previews always agree.
    public func drawnLabel(from label: String) -> String {
        let cased = uppercase ? label.uppercased() : label
        return String(cased.prefix(maxLabelLength))
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
