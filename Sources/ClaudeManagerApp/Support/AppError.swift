import Foundation

/// A user-facing message, presented by `RootView` through `.alert(_:isPresented:presenting:)`.
///
/// Carries its own `title` because this is the app's only alert channel and not everything
/// routed through it is a failure — a removal that kept shared profile data, or a batch
/// rebuild reporting what it skipped, are outcomes the user has to act on, and "Something
/// went wrong" over them is simply untrue. The heading is a plain argument to that modifier
/// rather than something the `presenting:` closure supplies, which is why `RootView` holds it
/// in view state instead of reading it back off this published value.
struct AppError: Identifiable {
    /// The heading for anything that genuinely is a failure — the common case, so it stays
    /// the default rather than being spelled at every call site.
    static let defaultTitle = "Something went wrong"

    let id = UUID()
    let title: String
    let message: String

    init(title: String = AppError.defaultTitle, message: String) {
        self.title = title
        self.message = message
    }

    /// Prefer a domain error's `errorDescription` over the opaque `localizedDescription`.
    init(_ error: Error) {
        self.init(message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
    }
}

/// A message-carrying error so a thrown failure can surface a specific reason (e.g.
/// the concrete `locateError`) through the editor's alert instead of a generic one.
struct MessageError: LocalizedError {
    let message: String
    var errorDescription: String? {
        message
    }
}
