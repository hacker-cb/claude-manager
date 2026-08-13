import Foundation

/// What to put in front of the user about a removal, when there is anything to say.
///
/// Both halves come from here rather than the heading being written at the call site: the
/// app has one alert channel and the heading is what says whether this is a failure, so a
/// heading chosen next to the presenter drifts from the sentence it sits above.
public struct RemovalNotice: Sendable, Equatable {
    public let title: String
    public let message: String

    public init(title: String, message: String) {
        self.title = title
        self.message = message
    }
}

/// What became of a profile's user-data directory when its launcher was removed.
///
/// Deleting that data is the destructive half of a removal — it holds the profile's Anthropic
/// login and its chat history — and `remove` can decline, or fail, in ways the user cannot see
/// from the outside. A `Bool` reported only *whether* it happened, which left the cases worth
/// saying out loud ("you asked to delete this and it is still on disk, here is why")
/// indistinguishable from the ones that need no words at all.
public enum ProfileDataOutcome: Sendable, Equatable {
    /// Deleted, as asked. The `-3p` managed-config overlay sibling goes too — except where
    /// that path is *another launcher's* user-data directory, which is spared (see
    /// `purgeProfileData`). So this does not promise the profile left nothing behind.
    case purged
    /// Deletion was asked for and **declined**: the launchers named here use directories that
    /// overlap this one — the same path, or one nested inside the other — so deleting it would
    /// take their login and history with it. Carries their display names because the remedy is
    /// per-launcher.
    case keptSharedWith(launchers: [String])
    /// Deletion was asked for and declined because the directory is the **default profile's**
    /// own — the one Claude itself uses. It owns no launcher, so it appears in no scan and
    /// `keptSharedWith` cannot name it; pointing a clone at it to reuse an existing login is
    /// a supported thing to do, and purging from there would sign the user out of Claude.
    case keptForDefaultProfile
    /// Deletion was asked for and declined because **whether anyone else uses this directory
    /// could not be established**: the launcher folder could not be listed, and that is where
    /// the answer lives. An empty scan is what an unreadable folder and an empty one look like
    /// from the inside, so treating it as "nobody else claims this" deletes a sibling's login
    /// on a folder that was merely renamed, unmounted, or had its permissions changed.
    case keptOwnersUnknown
    /// Deletion was asked for and there was nothing at the path.
    case alreadyGone
    /// Deletion was not asked for — "Move Launcher to Trash (keep login)".
    case notRequested
    /// Deletion was asked for, was not declined, and **failed** — an undeletable file, a
    /// permission the user does not have. Carried rather than thrown: by this point the
    /// launcher is already in the Trash, so throwing reports the whole removal as failed while
    /// half of it has happened, and the half that did not is the half holding credentials.
    case purgeFailed(reason: String)

    /// What to tell the user, or `nil` when the removal did exactly what they asked.
    ///
    /// Three of the five are silent on purpose: two were never asked to delete anything or
    /// found nothing to delete, and announcing a purge that went through would be a
    /// notification for "the button did what it says".
    ///
    /// Lives here rather than in the app layer so it is covered by tests — `ClaudeManagerCore`
    /// is the only target the test suite builds against, and a sentence telling someone their
    /// credentials are still on disk is worth a test.
    public func notice(forRemovalOf displayName: String) -> RemovalNotice? {
        switch self {
        case .purged, .alreadyGone, .notRequested:
            nil
        case let .keptSharedWith(launchers):
            Self.sharedNotice(displayName: displayName, launchers: launchers)
        case .keptForDefaultProfile:
            RemovalNotice(
                title: "Profile data was kept",
                message: "\(displayName) used the default profile's own folder, so its login "
                    + "and chat history are Claude's own — deleting them from here would sign "
                    + "you out of Claude itself. The launcher is in the Trash; the data is "
                    + "untouched."
            )
        case .keptOwnersUnknown:
            RemovalNotice(
                title: "Profile data was kept",
                message: "\(displayName)'s launcher is in the Trash, but its profile data was "
                    + "left alone: the launcher folder could not be read, so there was no way "
                    + "to tell whether another profile still uses that data. Once the folder "
                    + "is reachable again, remove the launcher's data from any profile that "
                    + "still lists it."
            )
        case let .purgeFailed(reason):
            RemovalNotice(
                title: "Profile data wasn't deleted",
                message: "\(displayName)'s launcher is in the Trash, but its profile data "
                    + "could not be deleted: \(Sentences.terminated(reason)) The login and "
                    + "chat history are still on disk."
            )
        }
    }

    /// The refusal, named concretely enough to act on. It says which button does the deletion,
    /// because the removal dialog leads with **Move Launcher to Trash (keep login)** — the
    /// non-destructive one — and a user following "remove it too" into that button ends up with
    /// no launcher left through which the data could ever be deleted.
    private static func sharedNotice(displayName: String, launchers: [String]) -> RemovalNotice? {
        guard !launchers.isEmpty else { return nil }
        let single = launchers.count == 1
        return RemovalNotice(
            title: "Profile data was kept",
            message: "Deleting \(displayName)'s profile data would have deleted the data for "
                + "\(Sentences.list(launchers)) too — the folders overlap — so it was left "
                + "alone, login and chat history included. Remove "
                + "\(single ? "that launcher" : "those launchers") with “Move to Trash and "
                + "Delete Profile Data” to delete it."
        )
    }
}
