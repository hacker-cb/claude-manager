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
    func rejectsDisplayNamesWithSeparatorsOrControlChars() {
        // The display name becomes the .app filename, so path separators, a leading
        // dot, and control characters must be rejected to keep it a single component.
        #expect(!Profile.isValidDisplayName("has/slash"))
        #expect(!Profile.isValidDisplayName("has:colon"))
        #expect(!Profile.isValidDisplayName("has\\backslash"))
        #expect(!Profile.isValidDisplayName("has\nnewline"))
        #expect(Profile.isValidDisplayName("Claude WORK")) // spaces are allowed
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
        #expect(restored.wrapperVersion == CoreConstants.currentWrapperVersion)
    }

    @Test
    func missingRequiredKeyYieldsNil() {
        #expect(LauncherMarker(dictionary: ["name": "x", "label": "X"]) == nil)
        #expect(LauncherMarker(dictionary: [:]) == nil)
    }

    @Test
    func defaultsWrapperVersionToOneWhenAbsent() throws {
        // A pre-versioning launcher (no wrapperVersion key, or only the old
        // schemaVersion key) reads back as v1 — i.e. stale — with no legacy fallback.
        let dict: [String: Any] = ["name": "a", "label": "A", "color": "red", "profile": "/p"]
        #expect(try #require(LauncherMarker(dictionary: dict)).wrapperVersion == 1)
        let legacy: [String: Any] = [
            "name": "a",
            "label": "A",
            "color": "red",
            "profile": "/p",
            "schemaVersion": 1
        ]
        #expect(try #require(LauncherMarker(dictionary: legacy)).wrapperVersion == 1)
    }
}

struct ManagedProfileTests {
    private func makeProfile() -> Profile {
        Profile(
            name: "w", displayName: "W", label: "W", color: .named("blue"),
            profilePath: "/p", bundleID: "io.example.w", appPath: "/W.app"
        )
    }

    @Test
    func needsRebuildWhenBelowCurrentWrapperVersion() {
        let stale = ManagedProfile(profile: makeProfile(), pid: nil, wrapperVersion: 1)
        #expect(stale.needsRebuild == (CoreConstants.currentWrapperVersion > 1))
        let current = ManagedProfile(
            profile: makeProfile(), pid: nil, wrapperVersion: CoreConstants.currentWrapperVersion
        )
        #expect(!current.needsRebuild)
    }

    @Test
    func isUnrunnableOnlyBelowTheSigningFloor() {
        // The app words these differently — "won't launch" vs "update available" — so a
        // pre-signing launcher must never read as merely dated.
        let unsigned = ManagedProfile(
            profile: makeProfile(), pid: nil,
            wrapperVersion: CoreConstants.minimumRunnableWrapperVersion - 1
        )
        #expect(unsigned.isUnrunnable)
        #expect(unsigned.needsRebuild)
        let current = ManagedProfile(
            profile: makeProfile(), pid: nil, wrapperVersion: CoreConstants.currentWrapperVersion
        )
        #expect(!current.isUnrunnable)
    }

    @Test
    func claudeUpdateAvailableOnlyWhenRunningBehindTheDiskVersion() {
        func managed(pid: Int32?, running: String?, available: String?) -> ManagedProfile {
            ManagedProfile(
                profile: makeProfile(), pid: pid,
                runningClaudeVersion: running, availableClaudeVersion: available
            )
        }
        // Running an older build than the app on disk → offer a restart.
        #expect(managed(pid: 42, running: "1.17377.2", available: "1.18286.0").claudeUpdateAvailable)
        // Already current, or ahead (a local downgrade), never prompts.
        #expect(!managed(pid: 42, running: "1.18286.0", available: "1.18286.0").claudeUpdateAvailable)
        #expect(!managed(pid: 42, running: "1.18286.0", available: "1.17377.2").claudeUpdateAvailable)
        // Stopped, or version unknown, is not actionable.
        #expect(!managed(pid: nil, running: "1.17377.2", available: "1.18286.0").claudeUpdateAvailable)
        #expect(!managed(pid: 42, running: nil, available: "1.18286.0").claudeUpdateAvailable)
        #expect(!managed(pid: 42, running: "1.17377.2", available: nil).claudeUpdateAvailable)
    }

    @Test
    func attentionsCollapseTheHealthAxisButNeverMaskTheRestartNudge() {
        func managed(
            wrapper: Int, pid: Int32? = nil, running: String? = nil, available: String? = nil
        ) -> ManagedProfile {
            ManagedProfile(
                profile: makeProfile(), pid: pid, wrapperVersion: wrapper,
                runningClaudeVersion: running, availableClaudeVersion: available
            )
        }
        let current = CoreConstants.currentWrapperVersion
        let unsigned = CoreConstants.minimumRunnableWrapperVersion - 1

        // Nothing to say when the launcher is current and the running build is too.
        #expect(managed(wrapper: current).attentions.isEmpty)
        // An unsigned launcher satisfies `needsRebuild` as well, and the health axis must not let
        // the mandatory rebuild be worded as the optional one.
        #expect(managed(wrapper: unsigned).attentions == [.unrunnable])
        // The two axes are independent: a restart nudge stands on its own, and would stand beside
        // a health mark rather than behind it.
        #expect(
            managed(wrapper: current, pid: 42, running: "1.0.0", available: "2.0.0").attentions
                == [.claudeUpdate(version: "2.0.0")]
        )
    }

    @Test
    func theSigningFloorNeverRisesAboveTheCurrentWrapper() {
        // What makes `attentions`' health precedence load-bearing: `isUnrunnable` must stay a
        // *subset* of `needsRebuild`, so a launcher macOS refuses to execute always also counts as
        // stale and the `else if` can never be reached first.
        #expect(CoreConstants.minimumRunnableWrapperVersion <= CoreConstants.currentWrapperVersion)
    }

    @Test
    func aStaleButRunnableLauncherIsNudged() throws {
        // The state between the two constants: signed (so macOS runs it) but behind the current
        // format. It first became constructible when the wrapper went to 4 over a signing floor of
        // 3 — the content-addressed badge bump — and it is the state every existing launcher lands
        // in on upgrade, so the soft nudge has to be the one it gets. The precedence in
        // `attentions` is only observable here: while the two constants were equal, no version sat
        // between them and the `else if` could not be reached.
        try #require(
            CoreConstants.minimumRunnableWrapperVersion < CoreConstants.currentWrapperVersion,
            "no wrapper version sits between the signing floor and the current format"
        )
        let stale = ManagedProfile(
            profile: makeProfile(), pid: nil, wrapperVersion: CoreConstants.currentWrapperVersion - 1
        )
        #expect(stale.needsRebuild)
        #expect(!stale.isUnrunnable)
        #expect(stale.attentions == [.rebuildAvailable])
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

struct ProfileDataOutcomeTests {
    /// The three silent outcomes. Each one *is* what the user asked for, so an alert here
    /// would be a notification that the button worked.
    @Test
    func outcomesThatMatchTheRequestSayNothing() {
        for outcome: ProfileDataOutcome in [.purged, .alreadyGone, .notRequested] {
            #expect(outcome.notice(forRemovalOf: "Work") == nil)
        }
    }

    /// An empty holder list would produce "…: still point at the same folder", naming nobody
    /// and offering no remedy. It cannot arise from `remove` (the outcome is only built from a
    /// non-empty filter), but the sentence must not depend on that staying true.
    @Test
    func sharedWithNobodySaysNothing() {
        #expect(ProfileDataOutcome.keptSharedWith(launchers: []).notice(forRemovalOf: "Work") == nil)
    }

    @Test
    func oneHolderIsNamedInTheSingular() throws {
        let outcome = ProfileDataOutcome.keptSharedWith(launchers: ["Personal"])
        let notice = try #require(outcome.notice(forRemovalOf: "Work"))
        #expect(notice.title == "Profile data was kept")
        #expect(notice.message.contains("would have deleted the data for Personal too"))
        #expect(notice.message.contains("Remove that launcher"))
    }

    /// Two and three holders differ only in the joining, and both have to read as English —
    /// the list is dropped straight into a sentence. Never as a possessive: "Personal and
    /// Test's" reads as belonging to Test alone.
    @Test
    func severalHoldersAreJoinedAndPluralized() throws {
        let two = ProfileDataOutcome.keptSharedWith(launchers: ["Personal", "Test"])
        let twoNotice = try #require(two.notice(forRemovalOf: "Work"))
        #expect(twoNotice.message.contains("the data for Personal and Test too"))
        #expect(twoNotice.message.contains("Remove those launchers"))
        #expect(!twoNotice.message.contains("Test's"))

        let three = ProfileDataOutcome.keptSharedWith(launchers: ["Personal", "Test", "Spare"])
        let threeNotice = try #require(three.notice(forRemovalOf: "Work"))
        #expect(threeNotice.message.contains("the data for Personal, Test and Spare too"))
    }

    /// The remedy has to name the *destructive* button. The removal dialog leads with "Move
    /// Launcher to Trash (keep login)", and a user who follows a bare "remove it too" into
    /// that one ends up with no launcher left through which the data could ever be deleted.
    @Test
    func theRemedyNamesTheButtonThatActuallyDeletes() throws {
        let outcome = ProfileDataOutcome.keptSharedWith(launchers: ["Personal"])
        let notice = try #require(outcome.notice(forRemovalOf: "Work"))
        #expect(notice.message.contains("“Move to Trash and Delete Profile Data”"))
    }

    /// A failed purge is not a refusal: the launcher is gone and the data is not, so the
    /// notice has to say both, and carry the reason.
    @Test
    func aFailedPurgeReportsWhereThingsStand() throws {
        let outcome = ProfileDataOutcome.purgeFailed(reason: "Permission denied.")
        let notice = try #require(outcome.notice(forRemovalOf: "Work"))
        #expect(notice.title == "Profile data wasn't deleted")
        #expect(notice.message.contains("Work's launcher is in the Trash"))
        #expect(notice.message.contains("Permission denied."))
        #expect(notice.message.contains("still on disk"))
    }

    /// The reason comes from Foundation or from an interpolated error, so whether it ends in a
    /// full stop is not ours to know — and a sentence follows it either way.
    @Test
    func aFailedPurgeDoesNotRunTheReasonIntoTheNextSentence() throws {
        let outcome = ProfileDataOutcome.purgeFailed(reason: "Permission denied")
        let notice = try #require(outcome.notice(forRemovalOf: "Work"))
        #expect(notice.message.contains("Permission denied. The login"))
    }
}

struct SentencesTests {
    @Test
    func listReadsAsEnglish() {
        #expect(Sentences.list([]).isEmpty)
        #expect(Sentences.list(["A"]) == "A")
        #expect(Sentences.list(["A", "B"]) == "A and B")
        #expect(Sentences.list(["A", "B", "C"]) == "A, B and C")
    }

    @Test
    func terminatedAddsAFullStopOnlyWhereOneIsMissing() {
        #expect(Sentences.terminated("Denied") == "Denied.")
        #expect(Sentences.terminated("Denied.") == "Denied.")
        #expect(Sentences.terminated("Denied!") == "Denied!")
        #expect(Sentences.terminated("Denied?") == "Denied?")
        // Trailing whitespace would otherwise put the stop after the gap.
        #expect(Sentences.terminated("  Denied \n") == "Denied.")
        #expect(Sentences.terminated("").isEmpty)
    }
}
