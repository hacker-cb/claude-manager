import ClaudeManagerCore
import Foundation

/// The single off-main dispatch path for store operations, shared by every `AppModel`
/// extension (e.g. `AppModel+PrimaryProfile`).
extension AppModel {
    /// Run a store operation off the main actor — it may block or suspend (e.g. the async
    /// `stop`) — surfacing errors as an alert. Returns `nil` on failure.
    func perform<T: Sendable>(
        _ body: @Sendable @escaping (ProfileStore) async throws -> T
    ) async -> T? {
        guard let real = realClaude, let config = currentConfiguration() else {
            currentError = AppError(message: locateError ?? "Real Claude.app was not found.")
            return nil
        }
        inflight += 1
        defer { inflight -= 1 }
        do {
            return try await Task.detached {
                let store = ProfileStore(realClaude: real, configuration: config)
                return try await body(store)
            }.value
        } catch {
            currentError = AppError(error)
            return nil
        }
    }

    /// Like `perform`, but re-throws instead of routing the error to `currentError`. The caller
    /// (the editor) presents the failure in its own sheet-level alert.
    func performThrowing<T: Sendable>(
        _ body: @Sendable @escaping (ProfileStore) async throws -> T
    ) async throws -> T {
        guard let real = realClaude, let config = currentConfiguration() else {
            // Preserve the specific locate reason (mirrors `perform`'s alert) rather than a
            // generic realClaudeNotFound, since the editor shows this directly.
            throw MessageError(message: locateError ?? "Real Claude.app was not found.")
        }
        inflight += 1
        defer { inflight -= 1 }
        return try await Task.detached {
            let store = ProfileStore(realClaude: real, configuration: config)
            return try await body(store)
        }.value
    }

    nonisolated static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    /// Build a store for synchronous, non-blocking calls (e.g. `draft`).
    func makeStore() -> ProfileStore? {
        guard let real = realClaude, let config = currentConfiguration() else { return nil }
        return ProfileStore(realClaude: real, configuration: config)
    }

    /// A seeded `Profile` for the editor, synchronously (no store mutation).
    func draft(
        name: String,
        label: String? = nil,
        color: BadgeColor? = nil,
        displayName: String? = nil,
        bundleID: String? = nil,
        profilePath: String? = nil
    ) -> Profile? {
        makeStore()?.draft(
            name: name, label: label, color: color,
            displayName: displayName, bundleID: bundleID, profilePath: profilePath
        )
    }
}
