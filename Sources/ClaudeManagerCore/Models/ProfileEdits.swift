import Foundation

/// The parts of a profile an edit is allowed to change.
///
/// `update` used to take a whole `Profile` as its target, which made these four fields
/// indistinguishable from the three that are the profile's *identity* — its name, its
/// user-data directory, and the bundle path derived from them. The core could not tell "the
/// user changed the badge colour" from "the caller swapped the user-data directory", and the
/// only thing preventing the second was that the editor has no field for it: an invariant
/// held in a SwiftUI form, which is the layer this project keeps deliberately thin.
///
/// What that allowed, spelled out: a `profilePath` changed through `update` makes the launcher
/// point at a new directory, seeds the managed-config overlay there, and leaves the old one —
/// holding the profile's Anthropic token and its chat history — behind as an orphan nothing
/// knows about. The profile silently loses its login.
///
/// Passing the identity separately makes that unrepresentable rather than merely unreachable.
/// `Profile.name` and `Profile.profilePath` are `let` for the other half of it: without that,
/// the same substitution is one mutation away on the profile argument itself.
///
/// Relocating profile data is a real operation, just not this one — it has to move the
/// directory and its `-3p` overlay, refuse to overlap another launcher's data, and require a
/// stopped instance. It belongs in a command of its own, and none exists yet.
public struct ProfileEdits: Sendable, Equatable {
    /// Finder/Dock name. The launcher's path is re-derived from this, so it is also what
    /// renames the bundle.
    public var displayName: String
    /// Badge text.
    public var label: String
    /// Badge fill colour.
    public var color: BadgeColor
    /// Launcher `CFBundleIdentifier`.
    public var bundleID: String

    public init(displayName: String, label: String, color: BadgeColor, bundleID: String) {
        self.displayName = displayName
        self.label = label
        self.color = color
        self.bundleID = bundleID
    }

    /// The profile's current values — what an editor opens with, and what "Save" on an
    /// unmodified form submits.
    public init(_ profile: Profile) {
        self.init(
            displayName: profile.displayName,
            label: profile.label,
            color: profile.color,
            bundleID: profile.bundleID
        )
    }
}
