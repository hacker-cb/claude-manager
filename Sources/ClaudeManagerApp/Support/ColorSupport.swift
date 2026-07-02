import AppKit
import ClaudeManagerCore
import SwiftUI

extension RGBAColor {
    var swiftUIColor: Color {
        Color(
            .sRGB,
            red: Double(red) / 255,
            green: Double(green) / 255,
            blue: Double(blue) / 255,
            opacity: Double(alpha) / 255
        )
    }

    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
        func channel(_ value: CGFloat) -> UInt8 {
            UInt8(min(255, max(0, (value * 255).rounded())))
        }
        self.init(
            red: channel(ns.redComponent),
            green: channel(ns.greenComponent),
            blue: channel(ns.blueComponent)
        )
    }
}

extension BadgeColor {
    var swiftUIColor: Color {
        rgba.swiftUIColor
    }
}
