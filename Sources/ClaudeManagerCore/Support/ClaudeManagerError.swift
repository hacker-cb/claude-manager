import Foundation

/// Every recoverable failure the core can surface. `LocalizedError` so the app can
/// present `errorDescription` directly in an alert.
public enum ClaudeManagerError: Error, LocalizedError, Equatable {
    case realClaudeNotFound
    case commandLaunchFailed(executable: String, message: String)
    case commandFailed(executable: String, exitCode: Int32, message: String)
    case launcherNotFound(name: String)
    case launcherAlreadyExists(path: String)
    case profileRunning(name: String, pid: Int32)
    /// A purge was asked for over a directory that *contains* another launcher's user-data
    /// dir. Refused before anything is touched — see `remove`.
    case profileDataHoldsAnother(name: String, others: [String])
    /// A rename could not retire the old bundle, and the edit was rolled back — see `update`.
    case renameUndone(path: String, reason: String)
    /// A rename could not retire the old bundle *and* could not roll itself back, so both
    /// launchers are on disk pointing at one profile — see `update`. Distinct from
    /// `renameUndone` because the state, and therefore the remedy, is the opposite one.
    case renameLeftBothLaunchers(oldPath: String, newPath: String, reason: String)
    case invalidProfileName(String)
    case invalidDisplayName(String)
    case invalidBundleID(String)
    case invalidColor(String)
    case invalidHexColor(String)
    case iconGenerationFailed(String)
    case installDirectoryNotWritable(path: String)
    case markerMissing(path: String)
    /// `exitCode` is `nil` when `codesign` never ran (missing or unrunnable tool), so a
    /// status is never invented for a process that produced none.
    case codeSigningFailed(path: String, exitCode: Int32?, message: String)

    public var errorDescription: String? {
        switch self {
        case .realClaudeNotFound:
            return "Could not find the real Claude Desktop app. Install Claude.app first."
        case let .commandLaunchFailed(executable, message):
            return "Failed to launch \(executable): \(message)"
        case let .commandFailed(executable, exitCode, message):
            let detail = message.isEmpty ? "" : " — \(message)"
            return "\(executable) exited with code \(exitCode)\(detail)"
        case let .launcherNotFound(name):
            return "No launcher named \"\(name)\"."
        case let .launcherAlreadyExists(path):
            return "A launcher already exists at \(path). Use force to rebuild it."
        case let .profileRunning(name, pid):
            return "Profile \"\(name)\" is running (pid \(pid)). Stop it first."
        case let .renameUndone(path, reason):
            // No "delete it yourself" here: after the rollback that bundle is the profile's
            // only launcher, so trashing it would remove the profile from the app entirely.
            return "The launcher at \(PathUtils.abbreviatingHome(path)) could not be moved to "
                + "the Trash: \(Sentences.terminated(reason)) The edit was undone — nothing "
                + "changed. Try the rename again once that launcher can be moved."
        case let .renameLeftBothLaunchers(oldPath, newPath, reason):
            return "The launcher at \(PathUtils.abbreviatingHome(oldPath)) could not be moved "
                + "to the Trash: \(Sentences.terminated(reason)) Undoing the edit failed too, "
                + "so this profile now has two launchers — the one just named above, and "
                + "\(PathUtils.abbreviatingHome(newPath)). Move the first to the Trash in "
                + "Finder; until you do, both open this profile and either can start it."
        case let .profileDataHoldsAnother(name, others):
            let list = Sentences.list(others)
            return "\"\(name)\"'s profile data folder contains the data for \(list), so "
                + "deleting it would delete their login and chat history too. Remove \(list) "
                + "first, or use “Move Launcher to Trash (keep login)” to remove only the "
                + "launcher."
        case let .invalidProfileName(name):
            return "Invalid profile name \"\(name)\". Use letters, digits, dashes, or underscores."
        case let .invalidDisplayName(name):
            return "Invalid display name \"\(name)\". It can't be empty, start with a dot, or contain a slash or colon."
        case let .invalidBundleID(value):
            return "Invalid bundle identifier \"\(value)\". Use reverse-DNS form, e.g. com.example.app."
        case let .invalidColor(value):
            return "Unknown color \"\(value)\". Use a palette name or a #RRGGBB hex value."
        case let .invalidHexColor(value):
            return "Bad hex color \"\(value)\", expected #RRGGBB."
        case let .iconGenerationFailed(reason):
            return "Icon generation failed: \(reason)"
        case let .installDirectoryNotWritable(path):
            return "Cannot write launchers to \(path). Check permissions or choose another location."
        case let .markerMissing(path):
            return "\(path) is not a Claude Manager launcher (no marker in Info.plist)."
        case let .codeSigningFailed(path, exitCode, message):
            // Not cosmetic: macOS refuses to execute a launcher without a valid
            // signature, so an unsigned bundle would look like it "hangs and never opens".
            let detail = message.isEmpty ? "" : " — \(message)"
            let cause = exitCode.map { "codesign exited \($0)" } ?? "codesign could not be run"
            return "Could not sign the launcher at \(path), so macOS would refuse to run it "
                + "(\(cause))\(detail)."
        }
    }
}
