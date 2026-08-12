import ClaudeManagerCore
import Foundation

/// Removing a launcher, and saying what happened to the data behind it. Split out of
/// `AppModel` to keep that file within its length budget.
@MainActor
extension AppModel {
    /// Trash the launcher and, when asked, delete its profile data — surfacing the cases where
    /// that deletion did **not** happen.
    ///
    /// The result used to be discarded outright, which made the one destructive choice in this
    /// app the quietest thing it does: "Move to Trash and Delete Profile Data" over a
    /// user-data dir another launcher still points at removes the launcher, keeps the login
    /// and the chat history, and reported success. The refusal itself is right — the data
    /// belongs to that other launcher too — so what was missing was the sentence, not the
    /// deletion.
    func removeProfile(_ profile: Profile, purgeProfile: Bool) async {
        let result = await perform { store in try store.remove(profile, purgeProfile: purgeProfile) }
        // `nil` means `remove` threw, and `perform` has already surfaced that error; a second
        // alert about the data would only bury it. Every other outcome speaks for itself
        // through `notice`, which is silent unless there is something to act on.
        if let notice = result?.profileData.notice(forRemovalOf: profile.displayName) {
            currentError = AppError(title: "Profile data was kept", message: notice)
        }
        await refresh()
    }
}
