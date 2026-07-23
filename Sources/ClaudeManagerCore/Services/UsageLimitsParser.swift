import Foundation

/// Parses the `/api/oauth/usage` JSON body into a `UsageSnapshot`, defensively.
///
/// The schema is reverse-engineered and forward-evolving (new codename windows appear
/// as null fields; the per-model weekly limit's model changed Sonnet → Fable), so parsing
/// is **field-by-field over a `[String: Any]`** — never a single strict `Codable`. Every
/// field that is missing, mistyped, or unknown degrades to a sane default instead of
/// failing the whole snapshot: an unknown `kind` is kept in the "other" bucket, percents
/// are clamped, and a wholly unreadable body returns nil (caller serves the last sample).
///
/// The primary source is the self-describing `limits[]` array; the legacy typed fields
/// (`five_hour` / `seven_day` / `seven_day_sonnet` / `seven_day_opus`) are a fallback for
/// an older server that doesn't send `limits[]`.
public struct UsageLimitsParser: Sendable {
    public init() {}

    /// Parse a raw JSON body. Returns nil only when the bytes aren't a JSON object at all.
    public func parse(_ data: Data, capturedAt: Date? = nil) -> UsageSnapshot? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        return parse(object: object, capturedAt: capturedAt)
    }

    /// Parse an already-deserialized JSON object. Always succeeds (an empty/odd object
    /// yields an empty snapshot) so a partial body never crashes a background poll.
    public func parse(object: [String: Any], capturedAt: Date? = nil) -> UsageSnapshot {
        let rawLimits = (object["limits"] as? [[String: Any]]) ?? []
        let limits = rawLimits.isEmpty ? parseTypedFallback(object) : rawLimits.compactMap(parseLimit)
        let extra = parseExtra(object["extra_usage"] as? [String: Any])
        return UsageSnapshot(limits: limits, extra: extra, capturedAt: capturedAt)
    }

    // MARK: - limits[] entries

    private func parseLimit(_ dict: [String: Any]) -> UsageLimit? {
        // A window with no usable kind is meaningless — skip it (not a crash).
        guard let kind = string(dict["kind"]), !kind.isEmpty else { return nil }
        var modelName: String?
        if let scope = dict["scope"] as? [String: Any], let model = scope["model"] as? [String: Any] {
            modelName = string(model["display_name"])
        }
        return UsageLimit(
            rawKind: kind,
            group: string(dict["group"]),
            utilization: fraction(fromPercent: dict["percent"]),
            resetsAt: date(dict["resets_at"]),
            severity: UsageSeverity.parse(string(dict["severity"])),
            isActive: bool(dict["is_active"]),
            scopeModelName: modelName
        )
    }

    // MARK: - Typed fallback (older servers without limits[])

    private func parseTypedFallback(_ object: [String: Any]) -> [UsageLimit] {
        var out: [UsageLimit] = []
        if let window = typedWindow(object["five_hour"], kind: UsageLimit.kindSession) {
            out.append(window)
        }
        if let window = typedWindow(object["seven_day"], kind: UsageLimit.kindWeeklyAll) {
            out.append(window)
        }
        // Legacy per-model fields — carried as scoped windows with a static model label.
        for (key, model) in [("seven_day_sonnet", "Sonnet"), ("seven_day_opus", "Opus")] {
            guard let dict = object[key] as? [String: Any] else { continue }
            guard var window = typedWindow(dict, kind: UsageLimit.kindWeeklyScoped) else { continue }
            window.scopeModelName = model
            out.append(window)
        }
        return out
    }

    private func typedWindow(_ any: Any?, kind: String) -> UsageLimit? {
        guard let dict = any as? [String: Any] else { return nil }
        let util = fraction(fromPercent: dict["utilization"])
        let reset = dict["resets_at"]
        return UsageLimit(
            rawKind: kind,
            group: nil,
            utilization: util,
            resetsAt: date(reset),
            severity: .normal,
            // A present, non-null resets_at means an active window — even a value we can't
            // parse to a Date. Only null/absent counts as no reset (JSONSerialization bridges
            // `null` to NSNull, a non-nil Any, so a raw `!= nil` check would wrongly pass).
            // `present` is a cheap type check, so resets_at is parsed only once (for resetsAt:).
            isActive: util > 0 || present(reset)
        )
    }

    /// True when a JSON value is present and not `null`.
    private func present(_ any: Any?) -> Bool {
        guard let any, !(any is NSNull) else { return false }
        return true
    }

    // MARK: - extra_usage

    private func parseExtra(_ dict: [String: Any]?) -> ExtraUsage? {
        guard let dict else { return nil }
        let limitMinor = int(dict["monthly_limit"])
        // utilization is a percent when present; nil when unlimited/unreported.
        let util: Double? = dict["utilization"].flatMap(number).map { ($0 / 100).clamped(to: 0 ... 1) }
        return ExtraUsage(
            isEnabled: bool(dict["is_enabled"]),
            usedMinor: int(dict["used_credits"]) ?? 0,
            limitMinor: limitMinor,
            utilization: limitMinor == nil ? nil : util,
            currency: string(dict["currency"]) ?? "USD"
        )
    }

    // MARK: - Scalar coercion (JSONSerialization yields NSNumber/NSString/NSNull)

    private func string(_ any: Any?) -> String? {
        if let s = any as? String { return s }
        return nil
    }

    private func number(_ any: Any?) -> Double? {
        if let n = any as? NSNumber { return n.doubleValue }
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let s = any as? String { return Double(s) }
        return nil
    }

    private func int(_ any: Any?) -> Int? {
        if let n = any as? NSNumber { return n.intValue }
        if let i = any as? Int { return i }
        if let d = any as? Double { return Int(d) }
        if let s = any as? String { return Int(s) }
        return nil
    }

    private func bool(_ any: Any?) -> Bool {
        if let b = any as? Bool { return b }
        if let n = any as? NSNumber { return n.boolValue }
        return false
    }

    /// API percent (0…100) → clamped fraction (0…1); a missing/odd value is 0.
    private func fraction(fromPercent any: Any?) -> Double {
        guard let percent = number(any) else { return 0 }
        return (percent / 100).clamped(to: 0 ... 1)
    }

    private func date(_ any: Any?) -> Date? {
        guard let raw = string(any), !raw.isEmpty else { return nil }
        return UsageLimitsParser.parseISO8601(raw)
    }

    /// Robust ISO-8601 parse. The API emits microsecond fractional seconds and a
    /// `+00:00` offset (e.g. `2026-07-28T13:59:59.857285+00:00`); `ISO8601DateFormatter`
    /// handles milliseconds, so a `DateFormatter` fallback covers the 6-digit case.
    ///
    /// Formatters are built locally: `ISO8601DateFormatter`/`DateFormatter` are not
    /// `Sendable`, and this static helper may run off any thread, so a shared instance
    /// would be unsafe under strict concurrency. Parsing runs at most a few times per
    /// poll (minutes apart), so the construction cost is irrelevant.
    static func parseISO8601(_ raw: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: raw) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: raw) { return date }

        let fallback = DateFormatter()
        fallback.locale = Locale(identifier: "en_US_POSIX")
        fallback.timeZone = TimeZone(identifier: "UTC")
        fallback.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXXXX"
        return fallback.date(from: raw)
    }
}
