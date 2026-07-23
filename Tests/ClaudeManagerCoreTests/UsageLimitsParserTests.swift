import Foundation
import Testing
@testable import ClaudeManagerCore

struct UsageLimitsParserTests {
    private let parser = UsageLimitsParser()

    // MARK: - Fixtures

    //
    // Structure is faithful to real `/api/oauth/usage` bodies (codename null windows, the
    // `limits[]` array, the `weekly_scoped` Fable window, the cents/`monthly_limit` shape),
    // but the money numbers are neutral synthetic values — never a real account's spend.

    /// Max account: an active weekly-all limit, a scoped "Fable" weekly limit, and
    /// extra-usage *with* a monthly cap.
    private static let maxWithCap = """
    {
      "five_hour": {"utilization": 7.0, "resets_at": "2026-07-23T19:00:00.123456+00:00"},
      "seven_day": {"utilization": 54.0, "resets_at": "2026-07-28T13:59:59.857285+00:00"},
      "seven_day_sonnet": null,
      "seven_day_opus": null,
      "tangelo": null,
      "extra_usage": {
        "is_enabled": true, "monthly_limit": 100000, "used_credits": 4200,
        "utilization": 4.2, "currency": "USD"
      },
      "limits": [
        {"kind":"session","group":"session","percent":7,"severity":"normal","resets_at":"2026-07-23T19:00:00.123456+00:00","scope":null,"is_active":true},
        {"kind":"weekly_all","group":"weekly","percent":54,"severity":"warning","resets_at":"2026-07-28T13:59:59.857285+00:00","scope":null,"is_active":true},
        {"kind":"weekly_scoped","group":"weekly","percent":0,"severity":"normal","resets_at":null,
         "scope":{"model":{"id":null,"display_name":"Fable"},"surface":null},"is_active":false}
      ]
    }
    """

    /// Extra usage with NO cap (`monthly_limit: null`) — the "Unlimited" case.
    private static let unlimitedExtra = """
    {
      "extra_usage": {
        "is_enabled": true, "monthly_limit": null, "used_credits": 19193,
        "utilization": null, "currency": "USD"
      },
      "limits": [
        {"kind":"weekly_all","group":"weekly","percent":1,"severity":"normal","resets_at":"2026-07-30T08:00:00.555663+00:00","scope":null,"is_active":true}
      ]
    }
    """

    private func data(_ s: String) -> Data {
        Data(s.utf8)
    }

    // MARK: - limits[] as source of truth

    @Test
    func parsesLimitsArrayWithScopedModel() throws {
        let snap = try #require(parser.parse(data(Self.maxWithCap)))

        // Percent → fraction normalization.
        #expect(snap.session?.utilization == 0.07)
        #expect(snap.weeklyAll?.utilization == 0.54)
        #expect(snap.weeklyAll?.severity == .warning)
        #expect(snap.weeklyAll?.isActive == true)

        // The per-model weekly limit's model is data, read from scope.model.display_name.
        let scoped = snap.weeklyScoped
        #expect(scoped.count == 1)
        #expect(scoped.first?.scopeModelName == "Fable")
        #expect(scoped.first?.shortLabel == "7d·Fable")
    }

    @Test
    func bindingLimitIsHighestActive() throws {
        let snap = try #require(parser.parse(data(Self.maxWithCap)))
        // session 7% and weekly_all 54% are active; scoped 0% is not → binding = weekly_all.
        #expect(snap.bindingLimit?.isWeeklyAll == true)
        #expect(snap.bindingLimit?.utilization == 0.54)
    }

    @Test
    func parsesExtraUsageCentsWithCap() throws {
        let snap = try #require(parser.parse(data(Self.maxWithCap)))
        let extra = try #require(snap.extra)
        #expect(extra.isEnabled)
        #expect(extra.usedMinor == 4200) // cents
        #expect(extra.limitMinor == 100_000) // cents
        #expect(extra.isUnlimited == false)
        #expect(extra.utilization == 0.042)
    }

    @Test
    func unlimitedExtraHasNilLimitAndNilUtilization() throws {
        let snap = try #require(parser.parse(data(Self.unlimitedExtra)))
        let extra = try #require(snap.extra)
        #expect(extra.limitMinor == nil)
        #expect(extra.utilization == nil)
        #expect(extra.isUnlimited)
        #expect(extra.usedMinor == 19193)
    }

    // MARK: - Defensive behavior

    @Test
    func unknownKindIsKeptInOtherBucketNotDropped() throws {
        let json = """
        { "limits": [
            {"kind":"weekly_all","percent":10,"is_active":true},
            {"kind":"quantum_flux","percent":88,"severity":"critical","is_active":true}
        ] }
        """
        let snap = try #require(parser.parse(data(json)))
        #expect(snap.limits.count == 2)
        let other = snap.otherLimits
        #expect(other.count == 1)
        #expect(other.first?.rawKind == "quantum_flux")
        #expect(other.first?.isKnownKind == false)
        #expect(other.first?.shortLabel == "quantum_flux")
        // ...and a forward-version window still participates in the binding-limit pick.
        #expect(snap.bindingLimit?.rawKind == "quantum_flux")
    }

    @Test
    func percentsAreClamped() throws {
        let json = """
        { "limits": [
            {"kind":"session","percent":250,"is_active":true},
            {"kind":"weekly_all","percent":-5,"is_active":true}
        ] }
        """
        let snap = try #require(parser.parse(data(json)))
        #expect(snap.session?.utilization == 1.0)
        #expect(snap.weeklyAll?.utilization == 0.0)
    }

    @Test
    func limitWithoutKindIsSkippedNotCrashing() throws {
        let json = """
        { "limits": [ {"percent":50,"is_active":true}, {"kind":"session","percent":3} ] }
        """
        let snap = try #require(parser.parse(data(json)))
        #expect(snap.limits.count == 1)
        #expect(snap.session?.utilization == 0.03)
    }

    @Test
    func integerAndStringNumbersBothCoerce() throws {
        // percent as int and as string; both must land as fractions.
        let json = """
        { "limits": [
            {"kind":"session","percent":42,"is_active":true},
            {"kind":"weekly_all","percent":"30","is_active":true}
        ] }
        """
        let snap = try #require(parser.parse(data(json)))
        #expect(snap.session?.utilization == 0.42)
        #expect(snap.weeklyAll?.utilization == 0.30)
    }

    @Test
    func nonObjectBodyReturnsNil() {
        #expect(parser.parse(Data("not json".utf8)) == nil)
        #expect(parser.parse(Data("[1,2,3]".utf8)) == nil)
    }

    @Test
    func emptyObjectYieldsEmptySnapshotNoCrash() throws {
        let snap = try #require(parser.parse(Data("{}".utf8)))
        #expect(snap.limits.isEmpty)
        #expect(snap.extra == nil)
        #expect(snap.bindingLimit == nil)
    }

    // MARK: - Typed fallback (older server without limits[])

    @Test
    func fallsBackToTypedFieldsWhenLimitsAbsent() throws {
        let json = """
        {
          "five_hour": {"utilization": 12.0, "resets_at": "2026-07-23T19:00:00.000000+00:00"},
          "seven_day": {"utilization": 40.0, "resets_at": "2026-07-28T00:00:00.000000+00:00"},
          "seven_day_sonnet": {"utilization": 5.0, "resets_at": null}
        }
        """
        let snap = try #require(parser.parse(data(json)))
        #expect(snap.session?.utilization == 0.12)
        #expect(snap.weeklyAll?.utilization == 0.40)
        let scoped = snap.weeklyScoped
        #expect(scoped.first?.scopeModelName == "Sonnet")
        #expect(scoped.first?.utilization == 0.05)
    }

    // MARK: - Date parsing

    @Test
    func parsesMicrosecondISODate() {
        let date = UsageLimitsParser.parseISO8601("2026-07-28T13:59:59.857285+00:00")
        #expect(date != nil)
        // 2026-07-28T13:59:59Z ≈ this epoch; allow sub-second slack.
        let expected = Date(timeIntervalSince1970: 1_785_247_199)
        #expect(abs((date ?? .distantPast).timeIntervalSince1970 - expected.timeIntervalSince1970) < 1)
    }

    @Test
    func badDateStringIsNilNotCrash() throws {
        let json = """
        { "limits": [ {"kind":"session","percent":1,"resets_at":"not-a-date","is_active":true} ] }
        """
        let snap = try #require(parser.parse(data(json)))
        #expect(snap.session?.resetsAt == nil)
    }

    // MARK: - Snapshot Codable round-trip (the canonical snapshot_json for storage)

    @Test
    func snapshotRoundTripsThroughCodable() throws {
        let original = try #require(parser.parse(
            data(Self.maxWithCap),
            capturedAt: Date(timeIntervalSince1970: 1000)
        ))
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(UsageSnapshot.self, from: encoded)
        #expect(decoded == original)
    }
}
