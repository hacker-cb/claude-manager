import CoreGraphics
import Foundation
import ImageIO

/// Extracts the badge base image from the real app's `.icns`. Uses ImageIO
/// directly (no `iconutil` subprocess) and picks the largest representation.
public enum RealIconExtractor {
    public static func loadBaseIcon(from iconURL: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(iconURL as CFURL, nil) else {
            throw ClaudeManagerError.iconGenerationFailed("cannot open \(iconURL.lastPathComponent)")
        }
        let count = CGImageSourceGetCount(source)
        var best: CGImage?
        var bestWidth = 0
        for index in 0 ..< count {
            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            if image.width > bestWidth {
                best = image
                bestWidth = image.width
            }
        }
        guard let best else {
            throw ClaudeManagerError.iconGenerationFailed("no images in \(iconURL.lastPathComponent)")
        }
        return best
    }
}
