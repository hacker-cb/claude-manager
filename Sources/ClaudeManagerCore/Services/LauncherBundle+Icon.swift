import CryptoKit
import Foundation

/// The badge resource: what it is called, and whether a build changes it. Split out of
/// `LauncherBundle` to keep that file within its length budget.
public extension LauncherBundle {
    /// The `Contents/Resources` file name carrying `icnsData` — content-addressed, so the
    /// name changes exactly when the icon's bytes do.
    ///
    /// This is what makes an edited badge actually *appear*. A launcher rebuild presents
    /// the same bundle identity every time — same path, same `CFBundleIdentifier`, same
    /// `CFBundleVersion` (we ship a fixed `1`) — so when it also points at the same
    /// `Badge.icns`, IconServices has nothing to tell the new icon apart by and serves the
    /// image it already rendered. The resource name is the one part of that identity this
    /// app controls, so deriving it from the icon's own bytes is what makes an edited badge
    /// a thing the cache has never seen. The staging build always writes into a fresh
    /// directory, so the previous name is dropped with the bundle it belonged to rather
    /// than accumulating.
    ///
    /// `sha256(icns)[:16]` mirrors `TokenProvider.fingerprint`: 64 bits is far past any
    /// practical collision here, and the name stays short enough to read in Finder.
    static func iconFileName(for icnsData: Data) -> String {
        let hex = SHA256.hash(data: icnsData).map { String(format: "%02x", $0) }.joined()
        return "Badge-\(hex.prefix(16)).icns"
    }

    /// The `Contents/Resources` file name a bundle's recorded `CFBundleIconFile` refers to,
    /// or `nil` when it records nothing usable. The single place that value is interpreted,
    /// so every reader resolves it the same way:
    ///
    /// - `lastPathComponent` keeps the read inside `Contents/Resources`. A launcher bundle
    ///   is user-writable, so the recorded value is not trusted to be a bare file name.
    /// - The extension is optional in `CFBundleIconFile`, so restore it when absent —
    ///   otherwise a hand-written `Badge` resolves to no file at all.
    static func iconResourceName(recorded: String?) -> String? {
        guard let recorded, !recorded.isEmpty else { return nil }
        var name = (recorded as NSString).lastPathComponent
        guard !name.isEmpty, name != "/" else { return nil }
        if !name.hasSuffix(".icns") { name += ".icns" }
        return name
    }
}

extension LauncherBundle {
    /// Whether the badge this build is about to write differs from what the bundle
    /// installed at `appURL` presents — by the resource **name** it points at as well as by
    /// its bytes. Both are read from that bundle's own `CFBundleIconFile`, never a
    /// hardcoded name, which is also what keeps this correct against a launcher built
    /// before v4 whose badge is still the fixed `Badge.icns`.
    ///
    /// The name is checked on its own for one case, and it is the case this whole change
    /// exists for: a pre-v4 launcher that was already edited carries the *current* badge
    /// bytes behind a name IconServices has a stale render for. Comparing bytes alone
    /// calls that "unchanged", so the migration rebuild — the very moment the fix reaches
    /// that launcher — would decline to offer the Dock refresh its tile needs. After v4
    /// the name is derived from the bytes, so this adds nothing to an ordinary rebuild:
    /// same icon, same name, still unchanged.
    func installedIconDiffers(at appURL: URL, name: String, data: Data) -> Bool {
        let infoURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let info = RealClaude.plist(at: infoURL, fileManager: fileManager),
              let installedName = Self.iconResourceName(recorded: info["CFBundleIconFile"] as? String)
        else { return true } // nothing installed here yet, or unreadable — treat as changed
        guard installedName == name else { return true }
        // Same name still gets a byte check: it catches a truncated or hand-edited
        // resource, where the name promises bytes the file no longer holds.
        let installed = try? Data(
            contentsOf: appURL.appendingPathComponent("Contents/Resources")
                .appendingPathComponent(installedName)
        )
        return installed != data
    }
}
