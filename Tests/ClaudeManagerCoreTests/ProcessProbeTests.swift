import Testing
@testable import ClaudeManagerCore

struct ProcessProbeTests {
    let realBinary = "/Applications/Claude.app/Contents/MacOS/Claude"

    @Test
    func parsesLaunchdMainsAndExtractsProfile() {
        let ps = """
          501     1 /Applications/Claude.app/Contents/MacOS/Claude --user-data-dir=/data/work --foo
          777     1 /Applications/Claude.app/Contents/MacOS/Claude
        """
        let mains = ProcessProbe.parseMains(psOutput: ps)
        #expect(mains.count == 2)
        #expect(mains[0].pid == 501)
        #expect(mains[0].profilePath == "/data/work")
        #expect(mains[1].pid == 777)
        #expect(mains[1].profilePath == nil)
    }

    @Test
    func ignoresRendererChildrenAndFrameworks() {
        let ps = """
          501     1 /Applications/Claude.app/Contents/MacOS/Claude --user-data-dir=/data/work
          502   501 /Applications/Claude.app/Contents/MacOS/Claude --type=renderer --user-data-dir=/data/work
          503   501 /Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper --type=gpu
          900     1 /Applications/Safari.app/Contents/MacOS/Safari
        """
        let mains = ProcessProbe.parseMains(psOutput: ps)
        #expect(mains.map(\.pid) == [501])
    }

    @Test
    func handlesSpacesInBundlePath() {
        let ps = "  610     1 /Applications/Claude P.app/Contents/MacOS/Claude --user-data-dir=/data/p"
        let mains = ProcessProbe.parseMains(psOutput: ps)
        #expect(mains.count == 1)
        #expect(mains[0].executablePath == "/Applications/Claude P.app/Contents/MacOS/Claude")
        #expect(mains[0].profilePath == "/data/p")
    }

    @Test
    func extractsProfilePathContainingSpaces() {
        // The default profiles dir lives under "Application Support/Claude Manager".
        let ps = "  501     1 /Applications/Claude.app/Contents/MacOS/Claude "
            + "--user-data-dir=/Users/x/Library/Application Support/Claude Manager/Profiles/work"
        let mains = ProcessProbe.parseMains(psOutput: ps)
        #expect(mains.count == 1)
        #expect(mains[0].profilePath == "/Users/x/Library/Application Support/Claude Manager/Profiles/work")
    }

    @Test
    func stopsProfileCaptureAtNextFlag() {
        let ps = "  501     1 /Applications/Claude.app/Contents/MacOS/Claude "
            + "--user-data-dir=/data/my work --enable-logging"
        let mains = ProcessProbe.parseMains(psOutput: ps)
        #expect(mains[0].profilePath == "/data/my work")
    }

    @Test
    func mainPIDUsesPgrepAndTrustsExitCode() {
        let running = RecordingCommandRunner { executable, _ in
            #expect(executable == CoreConstants.pgrepPath)
            return CommandOutput(exitCode: 0, standardOutput: "4242\n", standardError: "")
        }
        let probe = RecordingProbePair(running).probe
        #expect(probe.mainPID(forProfilePath: "/data/work", realBinaryPath: realBinary) == 4242)

        let stopped = RecordingCommandRunner { _, _ in
            CommandOutput(exitCode: 1, standardOutput: "", standardError: "")
        }
        #expect(ProcessProbe(runner: stopped)
            .mainPID(forProfilePath: "/data/work", realBinaryPath: realBinary) == nil)
    }

    @Test
    func mainPIDSendsEscapedPattern() {
        let runner = RecordingCommandRunner { _, _ in
            CommandOutput(exitCode: 1, standardOutput: "", standardError: "")
        }
        _ = ProcessProbe(runner: runner).mainPID(forProfilePath: "/data/p", realBinaryPath: realBinary)
        let call = try? #require(runner.invocations(of: CoreConstants.pgrepPath).first)
        #expect(call?.arguments.first == "-f")
        #expect(call?.arguments
            .last == #"^/Applications/Claude\.app/Contents/MacOS/Claude --user-data-dir=/data/p( |$)"#)
    }
}

/// Tiny helper so the closure-capturing runner test reads cleanly.
private struct RecordingProbePair {
    let probe: ProcessProbe
    init(_ runner: RecordingCommandRunner) {
        probe = ProcessProbe(runner: runner)
    }
}
