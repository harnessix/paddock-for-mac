import XCTest
@testable import PaddockKit

/// Binary discovery, the version gate and the prerequisites checklist.
final class DiscoveryTests: XCTestCase {
    let home = "/Users/demo"

    func locator(existing: Set<String>, env: [String: String] = [:], debug: Bool = true,
                 brew: String? = nil) -> BinaryLocator {
        BinaryLocator(environment: env, home: home, isDebugBuild: debug,
                      isExecutable: { existing.contains($0) }, brewPrefix: { _ in brew })
    }

    // Each of the five locations alone is found.
    func testEachLocationIsFound() {
        let cases: [(Set<String>, [String: String], String?, String)] = [
            (["/tmp/fake"], ["PADDOCK_BIN": "/tmp/fake"], nil, "/tmp/fake"),
            (["/opt/homebrew/bin/paddock"], [:], nil, "/opt/homebrew/bin/paddock"),
            (["/usr/local/bin/paddock"], [:], nil, "/usr/local/bin/paddock"),
            (["/Users/demo/.local/bin/paddock"], [:], nil, "/Users/demo/.local/bin/paddock"),
            (["/usr/local/bin/brew", "/usr/local/Cellar/x/bin/paddock"], [:], "/usr/local/Cellar/x\n",
             "/usr/local/Cellar/x/bin/paddock"),
        ]
        for (existing, env, brew, expected) in cases {
            XCTAssertEqual(locator(existing: existing, env: env, brew: brew).locate(), expected)
        }
    }

    // With all present, the first in order wins, one by one.
    func testFirstExistingWinsInOrder() {
        var all: Set<String> = ["/tmp/fake", "/opt/homebrew/bin/paddock", "/usr/local/bin/paddock",
                                "/Users/demo/.local/bin/paddock", "/opt/homebrew/bin/brew", "/brew/bin/paddock"]
        let env = ["PADDOCK_BIN": "/tmp/fake"]
        let order = ["/tmp/fake", "/opt/homebrew/bin/paddock", "/usr/local/bin/paddock",
                     "/Users/demo/.local/bin/paddock", "/brew/bin/paddock"]
        for expected in order {
            XCTAssertEqual(locator(existing: all, env: env, brew: "/brew").locate(), expected)
            all.remove(expected)
        }
        XCTAssertNil(locator(existing: all, env: env, brew: "/brew").locate())
    }

    func testMissingGivesNil() {
        XCTAssertNil(locator(existing: []).locate())
    }

    func testReleaseBuildIgnoresPaddockBin() {
        let found = locator(existing: ["/tmp/fake"], env: ["PADDOCK_BIN": "/tmp/fake"], debug: false).locate()
        XCTAssertNil(found)
    }

    func testSearchRootHidesRealInstallInDebug() {
        let l = locator(existing: ["/opt/homebrew/bin/paddock"], env: ["PADDOCK_LAUNCHER_SEARCH_ROOT": "/nowhere"])
        XCTAssertNil(l.locate())
    }

    @MainActor
    func testMissingBinaryShowsInstallCommand() async {
        let store = LauncherStore(service: nil)
        await store.start(locate: { nil }, makeService: { _ in fatalError("not called") })
        XCTAssertEqual(store.binary, .missing)
        XCTAssertTrue(store.needsOnboarding)
        let rows = Prerequisites.rows(doctor: nil, binary: nil, binaryMissing: true)
        let row = rows.first { $0.kind == .paddock }!
        XCTAssertEqual(row.command, "brew install harnessix/tap/paddock")
        XCTAssertEqual(row.result.english, "Not installed")
        XCTAssertEqual(LauncherError.notInstalled.primary.title?.english, "Check Again")
    }

    // MARK: Version gate

    func testVersionGate() {
        let gate = VersionGate(minimum: (0, 3), supportedMajor: 0)
        XCTAssertEqual(gate.check(versionOutput: "paddock 0.2.1\n"), .tooOld(have: "0.2.1", need: "0.3"))
        XCTAssertEqual(gate.check(versionOutput: "paddock 1.0.0"), .tooNew(have: "1.0.0"))
        XCTAssertEqual(gate.check(versionOutput: "paddock 0.3.0"), .ok(version: "0.3.0"))
        XCTAssertEqual(gate.check(versionOutput: "paddock 0.4.2"), .ok(version: "0.4.2"))
        XCTAssertEqual(gate.check(versionOutput: "v0.3"), .ok(version: "0.3.0"))
        XCTAssertEqual(gate.check(versionOutput: "garbage"), .unreadable(output: "garbage"))
    }

    // The launcher's own gate: paddock 0.2.2 or newer, by major, minor and
    // patch, any 0.x after it, never a 0.3 minimum.
    func testCurrentGateIsTwoTwoTwoWithPatch() {
        let gate = VersionGate.current
        XCTAssertEqual(gate.minimumText, "0.2.2")
        XCTAssertEqual(gate.check(versionOutput: "paddock 0.2.1\n"), .tooOld(have: "0.2.1", need: "0.2.2"))
        XCTAssertEqual(gate.check(versionOutput: "paddock 0.1.9"), .tooOld(have: "0.1.9", need: "0.2.2"))
        XCTAssertEqual(gate.check(versionOutput: "paddock 0.2.2"), .ok(version: "0.2.2"))
        XCTAssertEqual(gate.check(versionOutput: "paddock 0.2.10"), .ok(version: "0.2.10"))
        XCTAssertEqual(gate.check(versionOutput: "paddock 0.3.0"), .ok(version: "0.3.0"))
        XCTAssertEqual(gate.check(versionOutput: "paddock 0.2"), .tooOld(have: "0.2.0", need: "0.2.2"))
        XCTAssertEqual(gate.check(versionOutput: "paddock 0.2.2-dev"), .ok(version: "0.2.2"))
        XCTAssertEqual(gate.check(versionOutput: "paddock 1.0.0"), .tooNew(have: "1.0.0"))
        XCTAssertEqual(LauncherError.tooOld(have: "0.2.1", need: gate.minimumText).body?.english,
                       "This version of paddock for Mac needs paddock 0.2.2 or newer. You have 0.2.1.")
    }

    func testVersionGateTitles() {
        let gate = VersionGate.current
        XCTAssertEqual(gate.error(for: .tooOld(have: "0.2.1", need: "0.2.2"))?.title?.english, "Update paddock")
        XCTAssertEqual(gate.error(for: .tooNew(have: "1.0.0"))?.title?.english, "Update paddock for Mac")
        XCTAssertNil(gate.error(for: .ok(version: "0.3.0")))
    }

    @MainActor
    func testOldAndNewVersionStopTheStart() async throws {
        let old = try await Harness("old-version")
        XCTAssertEqual(old.store.binary, .found(path: "/fake/paddock", verdict: .tooOld(have: "0.2.1", need: "0.2.2")))
        XCTAssertTrue(old.calls(["app", "list"]).isEmpty)
        let new = try await Harness("new-version")
        XCTAssertEqual(new.store.binary, .found(path: "/fake/paddock", verdict: .tooNew(have: "1.0.0")))
        let ok = try await Harness("ready")
        XCTAssertTrue(ok.store.binary.isUsable)
    }

    // MARK: Prerequisites

    func rows(_ doctor: String) throws -> [PrereqRow] {
        Prerequisites.rows(doctor: try Fixtures.decode(DoctorJSON.self, doctor), binary: .ok(version: "0.4.2"),
                           binaryMissing: false)
    }

    // The rows of paddock's report: one per check, paddock's line verbatim.
    func testAppleSiliconPasses() throws {
        let r = try rows("doctor-ok.json")
        XCTAssertTrue(Prerequisites.canContinue(r))
        XCTAssertEqual(r.map(\.kind), [.chip, .macos, .paddock, .space, .memory, .entitlement, .slots])
        XCTAssertEqual(r[0].result.english, "This Mac has Apple silicon (Apple M2).")
        XCTAssertEqual(r[2].result.english, "paddock 0.4.2 found")
        XCTAssertEqual(r[3].result.english, "171.4 GiB free, 44 GiB needed.")
        XCTAssertEqual(r[4].result.english, "16 GiB: each app gets up to 8 GiB.")
        XCTAssertEqual(r[0].symbol, "checkmark.circle")
    }

    func testIntelIsADeadEnd() throws {
        let r = try rows("doctor-intel.json")
        XCTAssertFalse(Prerequisites.canContinue(r))
        XCTAssertTrue(Prerequisites.isDeadEnd(r))
        XCTAssertEqual(r[0].actions, [.quit])
        XCTAssertEqual(r[0].result.english,
                       "This Mac has an Intel chip (Intel Core i7). paddock app mode needs a Mac with Apple silicon.")
        XCTAssertEqual(r[0].symbol, "xmark.circle")
    }

    func testOldMacOSOffersUpdate() throws {
        let r = try rows("doctor-old-macos.json")
        XCTAssertFalse(Prerequisites.canContinue(r))
        XCTAssertEqual(r[1].status, .fail)
        XCTAssertEqual(r[1].actions, [.updateMacOS, .checkAgain])
        XCTAssertEqual(r[1].result.english,
                       "macOS 13.6. paddock app mode needs macOS 14 or newer: update macOS in System Settings.")
    }

    func testLowDiskOffersManageStorage() throws {
        let r = try rows("doctor-low-disk.json")
        XCTAssertFalse(Prerequisites.canContinue(r))
        XCTAssertEqual(r[3].kind, .space)
        XCTAssertEqual(r[3].actions, [.manageStorage, .checkAgain])
        XCTAssertEqual(r[3].result.english,
                       "11.2 GiB free, 44 GiB needed. Free up 32.8 GiB on the disk of ~/.local/share/paddock/macvm, then check again.")
    }

    func testLowMemoryIsOnlyAWarning() throws {
        let r = try rows("doctor-low-memory.json")
        XCTAssertTrue(Prerequisites.canContinue(r))
        XCTAssertEqual(r[4].status, .warning)
        XCTAssertEqual(r[4].result.english, "8 GiB: each app gets 4 GiB, the minimum.")
    }

    // A report without `checks` (the launcher's own look at this Mac when
    // paddock is missing): the rows come from the numbers.
    func derived(apple: Bool = true, macos: String = "15.1", macosOK: Bool = true,
                 free: Int64 = 184_000_000_000, memory: Int64 = 17_179_869_184) -> [PrereqRow] {
        let d = DoctorJSON(chip: DoctorChipJSON(appleSilicon: apple), disk: DoctorDiskJSON(free: free, need: 40_000_000_000),
                           macos: DoctorMacOSJSON(version: macos, ok: macosOK), memory: DoctorMemoryJSON(bytes: memory))
        return Prerequisites.rows(doctor: d, binary: .ok(version: "0.4.2"), binaryMissing: false)
    }

    func testDerivedRowsFromTheNumbers() {
        let r = derived()
        XCTAssertTrue(Prerequisites.canContinue(r))
        XCTAssertEqual(r.map(\.kind), [.chip, .macos, .paddock, .space, .memory])
        XCTAssertEqual(r[0].result.english, "This Mac has an M-series chip")
        XCTAssertEqual(r[1].result.english, "macOS 15.1")
        XCTAssertEqual(r[3].result.english, "184.0 GB free, 40.0 GB needed")
        XCTAssertEqual(r[4].result.english, "16 GB; each app gets up to 8 GB")

        let intel = derived(apple: false)
        XCTAssertTrue(Prerequisites.isDeadEnd(intel))
        XCTAssertEqual(intel[0].actions, [.quit])
        XCTAssertEqual(intel[0].result.english, "paddock app mode needs a Mac with Apple silicon.")

        let old = derived(macos: "13.6", macosOK: false)
        XCTAssertEqual(old[1].actions, [.updateMacOS, .checkAgain])
        XCTAssertEqual(old[1].result.english, "This Mac has macOS 13.6.")

        let low = derived(free: 12_000_000_000)
        XCTAssertEqual(low[3].actions, [.manageStorage, .checkAgain])
        XCTAssertEqual(low[3].result.english, "Needs 40.0 GB, 12.0 GB free. Free up space, then click Check again.")

        let small = derived(memory: 8_589_934_592)
        XCTAssertTrue(Prerequisites.canContinue(small))
        XCTAssertEqual(small[4].status, .warning)
        XCTAssertEqual(small[4].result.english, "8 GB; apps get 4 GB each, which is the minimum.")
    }

    // A check or a level of a newer paddock: shown with paddock's line, a
    // failed one with Check Again. An unknown level is a warning.
    func testUnknownChecksAndLevels() throws {
        let json = #"""
        {"v":1,"ok":false,"checks":[
          {"id":"apple_silicon","level":"ok","text":"This Mac has Apple silicon (Apple M4)."},
          {"id":"rosetta","level":"fail","text":"Rosetta is missing: run softwareupdate --install-rosetta."},
          {"id":"memory","level":"notice","text":"16 GiB."},
          {"id":"slots","level":"warn","text":"2 of 2 macOS VMs run: stop one first."},
          {"id":"entitlement","level":"fail","text":"paddock-vm lacks the Virtualization entitlement: brew reinstall paddock."},
          {"broken":true}
        ]}
        """#
        let d = try PaddockJSON.decoder.decode(DoctorJSON.self, from: Data(json.utf8))
        XCTAssertEqual(d.checks.count, 5, "a check that does not decode is left out")
        XCTAssertNil(d.chip)
        let r = Prerequisites.rows(doctor: d, binary: .ok(version: "0.2.2"), binaryMissing: false)
        XCTAssertEqual(r.map(\.kind), [.chip, .paddock, .memory, .entitlement, .slots, .other])
        XCTAssertEqual(r.map(\.status), [.pass, .pass, .warning, .fail, .warning, .fail])
        let other = r[5]
        XCTAssertEqual(other.id, "other-rosetta")
        XCTAssertEqual(other.title.english, "Rosetta")
        XCTAssertEqual(other.result.english, "Rosetta is missing: run softwareupdate --install-rosetta.")
        XCTAssertEqual(other.actions, [.checkAgain])
        XCTAssertEqual(r[3].actions, [.checkAgain])
        XCTAssertEqual(r[4].actions, [])
        XCTAssertFalse(Prerequisites.canContinue(r))
        XCTAssertFalse(Prerequisites.isDeadEnd(r))
        XCTAssertFalse(r.contains { $0.status == .checking })
    }

    func testNotADoctorReport() {
        XCTAssertThrowsError(try PaddockJSON.decoder.decode(DoctorJSON.self, from: Data(#"{"v":1,"ok":true}"#.utf8)))
        XCTAssertThrowsError(try PaddockJSON.decoder.decode(DoctorJSON.self, from: Data(#"{"checks":[]}"#.utf8)))
    }

    // A doctor that failed or did not answer is one failed row with Check
    // Again, never a row that still checks.
    func testDoctorWithoutReport() {
        for phase in [DoctorPhase.noAnswer, .failed("paddock: doctor: permission denied")] {
            let r = Prerequisites.rows(phase: phase, binary: .ok(version: "0.2.2"), binaryMissing: false)
            XCTAssertEqual(r.map(\.kind), [.paddock, .doctor])
            XCTAssertEqual(r[1].status, .fail)
            XCTAssertEqual(r[1].actions, [.checkAgain])
            XCTAssertFalse(Prerequisites.canContinue(r))
            XCTAssertFalse(r.contains { $0.status == .checking })
        }
        let silent = Prerequisites.rows(phase: .noAnswer, binary: .ok(version: "0.2.2"), binaryMissing: false)
        XCTAssertEqual(silent[1].result.english, "paddock did not answer in 20 seconds.")
        let failed = Prerequisites.rows(phase: .failed("permission denied"), binary: .ok(version: "0.2.2"), binaryMissing: false)
        XCTAssertEqual(failed[1].result.english, "paddock doctor gave no report: permission denied")
        let empty = Prerequisites.rows(phase: .report(DoctorJSON(checks: [], chip: nil)), binary: .ok(version: "0.2.2"),
                                       binaryMissing: false)
        XCTAssertEqual(empty.map(\.kind), [.paddock, .doctor])
        XCTAssertEqual(empty[1].result.english, "paddock doctor gave no checks.")
    }

    // The doctor runs with a 20 s limit: past it, paddock is killed and the
    // phase is `noAnswer`.
    @MainActor
    func testDoctorTimeLimit() async throws {
        let clock = FakeClock()
        let runner = ReplayRunner(clock: clock)
        runner.hang(prefix: "doctor --json")
        let service = CLIPaddockService(runner: runner)
        let box = PhaseBox()
        let task = Task { box.phase = await DoctorPhase.run(service) }
        await waitUntil { runner.hanging == 1 && clock.sleeperCount == 1 }
        clock.advance(DoctorPhase.limits.seconds - 1)
        await settle()
        XCTAssertNil(box.phase)
        clock.advance(1)
        await task.value
        XCTAssertEqual(box.phase, .noAnswer)
        XCTAssertEqual(runner.hanging, 0)
        XCTAssertEqual(runner.kills, 1)
    }

    // A non-zero exit without a report: paddock's last line.
    @MainActor
    func testDoctorFailureLine() async {
        let runner = ReplayRunner(clock: FakeClock())
        runner.on(PaddockArgs.doctor, json: "", status: 2, stderr: "error: unknown command doctor\n")
        let phase = await DoctorPhase.run(CLIPaddockService(runner: runner))
        XCTAssertEqual(phase, .failed("error: unknown command doctor"))
    }

    func testOldPaddockRowOffersUpgrade() {
        let r = Prerequisites.rows(doctor: nil, binary: .tooOld(have: "0.2.1", need: "0.2.2"), binaryMissing: false)
        let row = r.first { $0.kind == .paddock }!
        XCTAssertEqual(row.command, "brew upgrade paddock")
        XCTAssertEqual(row.status, .fail)
    }
}

@MainActor
final class PhaseBox {
    var phase: DoctorPhase?
}
