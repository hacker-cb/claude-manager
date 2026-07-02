import Foundation

/// One entry of a macOS `.iconset` — a point size at a scale factor.
public struct IconImageSize: Hashable, Sendable {
    public let points: Int
    public let scale: Int

    public init(points: Int, scale: Int) {
        self.points = points
        self.scale = scale
    }

    public var pixels: Int {
        points * scale
    }

    /// The exact filename `iconutil` expects inside a `.iconset` directory.
    public var iconsetFileName: String {
        scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@\(scale)x.png"
    }

    /// The standard 16/32/128/256/512 pt set at @1x and @2x.
    public static let standardSet: [IconImageSize] = [16, 32, 128, 256, 512].flatMap {
        [IconImageSize(points: $0, scale: 1), IconImageSize(points: $0, scale: 2)]
    }
}
