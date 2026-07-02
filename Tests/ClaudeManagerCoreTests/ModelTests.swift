import Testing
@testable import ClaudeManagerCore

struct ProfileDefaultsTests {
    @Test
    func computesDefaults() {
        #expect(Profile.defaultDisplayName(for: "work") == "Claude WORK")
        #expect(Profile.defaultLabel(for: "work") == "WO")
        #expect(Profile.defaultLabel(for: "p") == "P")
        #expect(Profile.defaultBundleID(for: "Work") == "io.github.hacker-cb.claude-manager.launcher.work")
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
