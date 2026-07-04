import Foundation

/// Packs per-size PNGs into a `.icns` via `iconutil` (the only supported way to
/// write the format). Runs in a throwaway temp directory.
public struct IcnsPacker {
    let runner: CommandRunner
    let fileManager: FileManager

    public init(runner: CommandRunner, fileManager: FileManager = .default) {
        self.runner = runner
        self.fileManager = fileManager
    }

    public func makeICNS(pngs: [IconImageSize: Data]) throws -> Data {
        let temp = fileManager.temporaryDirectory
            .appendingPathComponent("claude-manager-\(UUID().uuidString)", isDirectory: true)
        let iconset = temp.appendingPathComponent("badge.iconset", isDirectory: true)
        try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temp) }

        for (size, data) in pngs {
            try data.write(to: iconset.appendingPathComponent(size.iconsetFileName))
        }

        let output = temp.appendingPathComponent("badge.icns")
        try runner.runChecked(CoreConstants.iconutilPath, ["-c", "icns", iconset.path, "-o", output.path])

        guard let data = fileManager.contents(atPath: output.path) else {
            throw ClaudeManagerError.iconGenerationFailed("iconutil produced no output")
        }
        return data
    }
}

/// Convenience end-to-end pipeline: real app icon → badged `.icns` bytes.
public struct IconPipeline {
    let renderer: BadgeRenderer
    let packer: IcnsPacker

    public init(renderer: BadgeRenderer = BadgeRenderer(), packer: IcnsPacker) {
        self.renderer = renderer
        self.packer = packer
    }

    public func makeBadgeICNS(
        realClaude: RealClaude,
        label: String,
        color: BadgeColor,
        style: BadgeStyle = .default
    ) throws -> Data {
        guard let iconURL = realClaude.iconURL else {
            throw ClaudeManagerError.iconGenerationFailed("the real app has no icon resource")
        }
        let base = try RealIconExtractor.loadBaseIcon(from: iconURL)
        let pngs = try renderer.makeIconSet(base: base, label: label, color: color.rgba, style: style)
        return try packer.makeICNS(pngs: pngs)
    }
}
