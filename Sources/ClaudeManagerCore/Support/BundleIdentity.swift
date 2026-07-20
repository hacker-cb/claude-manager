import Foundation

/// What a *running* bundle is allowed to claim from the system, read off its own
/// Info.plist rather than off a build flag.
///
/// The app ships two identities: the released one (bundle id
/// `io.github.hacker-cb.claude-manager`, declares `claude://`) and the local dev one built
/// by `make run` (`…​.claude-manager.dev`, declares only the private `claude-cmdev://`).
/// They are separated at build time by the Xcode configuration — see project.yml
/// `settings.configs` — so macOS's bundle-id-keyed registries (LaunchServices, Login Items,
/// TCC, UserDefaults) can never confuse a working copy in `build/` for the installed app.
///
/// This type is the *runtime* half of that split. Keying the broker on what the bundle
/// actually declares — instead of a second, independently-maintained "am I a dev build?"
/// flag — means the two halves cannot drift: a build that does not declare `claude://`
/// cannot be registered as its handler no matter what the code attempts, and the UI
/// explains itself from the same fact.
public enum BundleIdentity {
    /// Whether `infoDictionary` declares `scheme` among its `CFBundleURLTypes`, i.e.
    /// whether this bundle is an eligible default handler for it. Matching is
    /// case-insensitive because URL schemes are (RFC 3986 §3.1), so a plist that spells
    /// the scheme `Claude` still counts.
    ///
    /// A missing, malformed, or partially-typed `CFBundleURLTypes` reads as "not
    /// declared": every entry that isn't a dictionary of string schemes is skipped rather
    /// than failing the whole lookup, so one bad entry can't mask a good one.
    public static func declaresURLScheme(_ scheme: String, in infoDictionary: [String: Any]?) -> Bool {
        guard let types = infoDictionary?["CFBundleURLTypes"] as? [[String: Any]] else { return false }
        let wanted = scheme.lowercased()
        return types.contains { entry in
            guard let schemes = entry["CFBundleURLSchemes"] as? [String] else { return false }
            return schemes.contains { $0.lowercased() == wanted }
        }
    }
}
