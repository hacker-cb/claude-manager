import Foundation

/// Straight 8-bit RGBA color, independent of AppKit/CoreGraphics so it is safe in
/// pure-logic code and tests.
public struct RGBAColor: Equatable, Hashable, Sendable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8
    public let alpha: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8 = 255) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// `#RRGGBB` (alpha dropped — badges are always opaque).
    public var hexString: String {
        String(format: "#%02X%02X%02X", red, green, blue)
    }
}

/// A badge fill color: either a named palette entry or an arbitrary custom color.
/// `storageString` round-trips through the launcher's Info.plist marker.
public enum BadgeColor: Equatable, Hashable, Sendable {
    case named(String)
    case custom(RGBAColor)

    /// The named palette — Apple's system accent colors, matching the reference
    /// tool's set plus a few extras.
    public static let palette: [(name: String, color: RGBAColor)] = [
        ("blue", RGBAColor(red: 10, green: 132, blue: 255)),
        ("green", RGBAColor(red: 48, green: 209, blue: 88)),
        ("orange", RGBAColor(red: 255, green: 159, blue: 10)),
        ("purple", RGBAColor(red: 191, green: 90, blue: 242)),
        ("red", RGBAColor(red: 255, green: 69, blue: 58)),
        ("gray", RGBAColor(red: 142, green: 142, blue: 147)),
        ("pink", RGBAColor(red: 255, green: 55, blue: 95)),
        ("teal", RGBAColor(red: 48, green: 176, blue: 199)),
        ("yellow", RGBAColor(red: 255, green: 214, blue: 10))
    ]

    public static let paletteNames: [String] = palette.map(\.name)

    /// Resolve to concrete RGBA. An unknown named color falls back to blue so a
    /// stale marker never crashes rendering.
    public var rgba: RGBAColor {
        switch self {
        case let .custom(color):
            color
        case let .named(name):
            Self.palette.first { $0.name == name }?.color
                ?? Self.palette[0].color
        }
    }

    /// Value stored in the launcher marker: the palette name, or `#RRGGBB`.
    public var storageString: String {
        switch self {
        case let .named(name): name
        case let .custom(color): color.hexString
        }
    }

    /// Human-facing label for the editor UI.
    public var displayName: String {
        switch self {
        case let .named(name): name.capitalized
        case let .custom(color): color.hexString
        }
    }

    /// Parse a palette name or a `#RRGGBB` hex string.
    public static func parse(_ raw: String) throws -> BadgeColor {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") {
            return try .custom(parseHex(value))
        }
        let lowered = value.lowercased()
        if paletteNames.contains(lowered) {
            return .named(lowered)
        }
        throw ClaudeManagerError.invalidColor(raw)
    }

    /// Parse `#RRGGBB` into an opaque `RGBAColor`.
    public static func parseHex(_ raw: String) throws -> RGBAColor {
        let hex = raw.hasPrefix("#") ? String(raw.dropFirst()) : raw
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else {
            throw ClaudeManagerError.invalidHexColor(raw)
        }
        return RGBAColor(
            red: UInt8((value >> 16) & 0xFF),
            green: UInt8((value >> 8) & 0xFF),
            blue: UInt8(value & 0xFF)
        )
    }
}
