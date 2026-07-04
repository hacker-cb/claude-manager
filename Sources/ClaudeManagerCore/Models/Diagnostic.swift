import Foundation

/// One line of `doctor` output.
public struct Diagnostic: Identifiable, Equatable, Sendable {
    public enum Severity: String, Sendable, CaseIterable {
        case ok
        case warning
        case error
    }

    public let severity: Severity
    public let title: String
    public let detail: String?

    public init(severity: Severity, title: String, detail: String? = nil) {
        self.severity = severity
        self.title = title
        self.detail = detail
    }

    /// Deterministic identity (no random UUID) so SwiftUI lists stay stable and
    /// tests can assert on it.
    public var id: String {
        "\(severity.rawValue)|\(title)|\(detail ?? "")"
    }
}

public extension Collection<Diagnostic> {
    /// True when no diagnostic is an error.
    var allHealthy: Bool {
        !contains { $0.severity == .error }
    }

    var hasWarnings: Bool {
        contains { $0.severity == .warning }
    }
}
