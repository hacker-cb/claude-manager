import Foundation

/// Asks Anthropic's desktop release API which Claude build is current.
///
/// **Why this endpoint and not the one Claude itself uses.** Claude Desktop's own updater
/// calls `…/squirrel/update?device_id=…&version=…`, which answers with the build rolled out
/// to that particular device and carries `sha256`/`size` alongside the URL. It is the richer
/// payload, but it is keyed on a per-profile `device_id` file and answers a question we are
/// not asking: Claude Manager replaces the one shared `/Applications/Claude.app` on demand,
/// so what it needs is simply *the latest release*. `zip/latest` answers exactly that, in
/// two fields, with no identifier attached.
///
/// **Losing `sha256` costs nothing here.** A digest served beside the download it describes
/// proves the bytes arrived intact, not that they are genuine — both come from the same
/// channel. Authenticity is established after the download by ``UpdateVerifier``, from the
/// bundle's own Apple Developer ID signature, its notarization ticket and its team
/// identifier, none of which this feed can influence. Transport integrity is TLS's job, and
/// the download is length-checked besides.
public struct UpdateFeed: Sendable {
    /// What went wrong asking the feed. Transport failures (offline, DNS, timeout) are
    /// thrown by the `HTTPClient` itself and pass straight through.
    public enum Failure: Error, Equatable {
        /// The feed answered, but not with 200.
        case unexpectedStatus(Int)
        /// The body was not the `{version, url}` object this feed is documented to return.
        case malformedPayload
        /// The payload named a download over something other than HTTPS. Refused rather
        /// than downgraded: everything downstream trusts that these bytes crossed TLS.
        case insecureDownloadURL
    }

    /// Default request timeout, aliased here so the signature stays on one line.
    /// `public` because it is a default argument of a `public` method.
    public static let defaultTimeout = CoreConstants.updateFeedTimeout

    let client: HTTPClient
    let endpoint: URL

    /// - Parameter endpoint: overridable so tests can point at a canned URL; production
    ///   uses ``CoreConstants/latestReleaseFeedURL``.
    public init(
        client: HTTPClient = URLSessionHTTPClient(),
        endpoint: URL = CoreConstants.latestReleaseFeedURL
    ) {
        self.client = client
        self.endpoint = endpoint
    }

    /// The latest published release.
    ///
    /// Says nothing about whether it is newer than what is installed — that comparison is
    /// ``AvailableUpdate/isUpgrade(over:)``, and the caller owns it, because "no update" and
    /// "the feed is unreachable" must not collapse into the same answer.
    public func latest(timeout: TimeInterval = Self.defaultTimeout) async throws -> AvailableUpdate {
        CoreLog.update.info("feed: asking \(endpoint.absoluteString, privacy: .public)")
        let response: HTTPResponse
        do {
            response = try await client.get(url: endpoint, headers: [:], timeout: timeout)
        } catch {
            // Logged here as well as rethrown: offline is the most common outcome of a
            // background check, and "we asked and could not reach it" has to be
            // distinguishable in a log from "we never asked".
            CoreLog.update.error("feed: transport failure — \(error.localizedDescription, privacy: .public)")
            throw error
        }
        guard response.status == 200 else {
            CoreLog.update.error("feed: unexpected status \(response.status, privacy: .public)")
            throw Failure.unexpectedStatus(response.status)
        }
        do {
            let update = try Self.parse(response.body)
            let url = update.downloadURL.logDescription
            CoreLog.update
                .info("feed: offers \(update.version, privacy: .public) at \(url, privacy: .public)")
            return update
        } catch {
            // What *shape* the answer had is public; the answer itself is not. A 200 that
            // fails to parse is often not release metadata at all but an interception page
            // from a corporate proxy or captive portal, which can name the user — so the
            // body stays `.private` while the facts that make a log triageable without it
            // (why it failed, how big it was, what it claimed to be) are public.
            let body = String(decoding: response.body.prefix(512), as: UTF8.self)
            let reason = String(describing: error)
            let contentType = response.header("content-type") ?? "unknown"
            CoreLog.update.error(
                """
                feed: malformed payload (\(reason, privacy: .public)), \
                \(response.body.count, privacy: .public) bytes of \
                \(contentType, privacy: .public) — body: \(body, privacy: .private)
                """
            )
            throw error
        }
    }

    /// Parse the feed body. Kept `static` and separate so the wire format is testable
    /// without a client at all.
    ///
    /// The version must parse as dotted-numeric, not merely be non-empty: `VersionOrder`
    /// reads a non-numeric component as `0`, so a feed that started answering `v1.40000.0`
    /// would parse, compare as `0.40000.0`, and read as "no update available" forever with
    /// nothing in the log to explain it. Refusing surfaces the reshape immediately.
    ///
    /// Unknown keys are ignored by construction, and both fields are required: a payload
    /// missing either one is malformed rather than partially usable, since a version with no
    /// download and a download with no version are each useless on their own.
    static func parse(_ body: Data) throws -> AvailableUpdate {
        guard let object = try? JSONSerialization.jsonObject(with: body),
              let dict = object as? [String: Any],
              let version = dict["version"] as? String,
              let urlString = dict["url"] as? String,
              VersionOrder.isComparable(version),
              let url = URL(string: urlString)
        else { throw Failure.malformedPayload }
        // `URL(string:)` accepts a bare string like `not a url at all` as a *relative* URL,
        // so "has no scheme" is the test for an unreadable value — not `URL` returning nil.
        guard let scheme = url.scheme?.lowercased() else { throw Failure.malformedPayload }
        // Checked before the host so that a `file:` URL — which parses fine and simply has
        // no host — is reported as the downgrade it is rather than as an unreadable
        // payload. Case-insensitive, since a scheme is not case-sensitive per RFC 3986 and
        // rejecting `HTTPS://` would be a bug rather than strictness.
        guard scheme == "https" else { throw Failure.insecureDownloadURL }
        guard url.host?.isEmpty == false else { throw Failure.malformedPayload }
        return AvailableUpdate(version: version, downloadURL: url)
    }
}
