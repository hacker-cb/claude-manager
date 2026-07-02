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
    case invalidProfileName(String)
    case invalidDisplayName(String)
    case invalidColor(String)
    case invalidHexColor(String)
    case iconGenerationFailed(String)
    case installDirectoryNotWritable(path: String)
    case markerMissing(path: String)

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
        case let .invalidProfileName(name):
            return "Invalid profile name \"\(name)\". Use letters, digits, dashes, or underscores."
        case let .invalidDisplayName(name):
            return "Invalid display name \"\(name)\". It can't be empty, start with a dot, or contain a slash or colon."
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
        }
    }
}
