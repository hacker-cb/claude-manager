import Testing
@testable import ClaudeManagerCore

struct ProfileDefaultsTests {
    @Test
    func computesDefaults() {
        #expect(Profile.defaultDisplayName(for: "work") == "Claude WORK")
        // Leading chars for a single word, initials for a multi-word name (split on
        // spaces/dashes/underscores), raw casing, capped at maxLength.
        #expect(Profile.defaultLabel(for: "work", maxLength: 3) == "wor")
        #expect(Profile.defaultLabel(for: "p", maxLength: 3) == "p")
        #expect(Profile.defaultLabel(for: "alex-mid-si", maxLength: 3) == "ams")
        #expect(Profile.defaultLabel(for: "Alex Mid Si", maxLength: 3) == "AMS")
        #expect(Profile.defaultLabel(for: "web_app", maxLength: 2) == "wa")
        #expect(Profile.defaultLabel(for: "a-b-c-d", maxLength: 3) == "abc")
        #expect(Profile.defaultBundleID(for: "Work") == "io.github.hacker-cb.claude-manager.launcher.work")
    }

    @Test
    func defaultLabelIsNeverBlankForAValidName() {
        // A name of only separators is valid per isValidName but yields no words; the
        // label must fall back to the raw name rather than render a blank badge.
        #expect(Profile.isValidName("-"))
        #expect(Profile.defaultLabel(for: "-", maxLength: 3) == "-")
        #expect(Profile.defaultLabel(for: "__", maxLength: 2) == "__")
    }

    @Test
    func validatesNames() {
        #expect(Profile.isValidName("work"))
        #expect(Profile.isValidName("work-2_test"))
        #expect(!Profile.isValidName(""))
        #expect(!Profile.isValidName("has space"))
        #expect(!Profile.isValidName("has/slash"))
        #expect(!Profile.isValidName("dot.dot"))
    }

    @Test
    func validatesDisplayNames() {
        #expect(Profile.isValidDisplayName("Claude WORK"))
        #expect(Profile.isValidDisplayName("a..b"))
        #expect(!Profile.isValidDisplayName(""))
        #expect(!Profile.isValidDisplayName("."))
        #expect(!Profile.isValidDisplayName(".hidden"))
        #expect(!Profile.isValidDisplayName("has/slash"))
        #expect(!Profile.isValidDisplayName("has:colon"))
    }

    @Test
    func validatesBundleIDs() {
        #expect(Profile.isValidBundleID("io.github.hacker-cb.claude-manager.launcher.work"))
        #expect(Profile.isValidBundleID("com.example.app"))
        #expect(!Profile.isValidBundleID("noDot"))
        #expect(!Profile.isValidBundleID("has space.app"))
        #expect(!Profile.isValidBundleID(".leading"))
        #expect(!Profile.isValidBundleID("trailing."))
        #expect(!Profile.isValidBundleID("double..dot"))
        #expect(!Profile.isValidBundleID("has/slash.app"))
    }

    @Test
    func identityIsAppPath() {
        let profile = Profile(
            name: "a", displayName: "Claude A", label: "A", color: .named("red"),
            profilePath: "/p", bundleID: "id", appPath: "/Applications/Claude A.app"
        )
        #expect(profile.id == "/Applications/Claude A.app")
        #expect(profile.appURL.lastPathComponent == "Claude A.app")
    }
}

struct LauncherMarkerTests {
    @Test
    func dictionaryRoundTrips() throws {
        let marker = LauncherMarker(name: "work", label: "W", color: "blue", profile: "/data/work")
        let restored = try #require(LauncherMarker(dictionary: marker.dictionary))
        #expect(restored == marker)
        #expect(restored.schemaVersion == CoreConstants.markerSchemaVersion)
    }

    @Test
    func missingRequiredKeyYieldsNil() {
        #expect(LauncherMarker(dictionary: ["name": "x", "label": "X"]) == nil)
        #expect(LauncherMarker(dictionary: [:]) == nil)
    }

    @Test
    func defaultsSchemaVersionWhenAbsent() throws {
        let dict: [String: Any] = ["name": "a", "label": "A", "color": "red", "profile": "/p"]
        let marker = try #require(LauncherMarker(dictionary: dict))
        #expect(marker.schemaVersion == 1)
    }
}

struct DiagnosticTests {
    @Test
    func healthAggregation() {
        let ok = Diagnostic(severity: .ok, title: "fine")
        let warn = Diagnostic(severity: .warning, title: "hmm")
        let err = Diagnostic(severity: .error, title: "bad")
        #expect([ok, warn].allHealthy)
        #expect([ok, warn].hasWarnings)
        #expect(![ok, warn, err].allHealthy)
    }

    @Test
    func identityIsDeterministic() {
        let a = Diagnostic(severity: .ok, title: "t", detail: "d")
        let b = Diagnostic(severity: .ok, title: "t", detail: "d")
        #expect(a.id == b.id)
    }
}
