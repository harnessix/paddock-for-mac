import Foundation
import XCTest
@testable import PaddockKit
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Scratch scripts for the tests of the shell environment. Every "shell"
/// here is a small `/bin/sh` script: no test runs the shell of the user.
final class Scratch {
    let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("shell-env-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: folder)
    }

    func file(_ name: String) -> URL { folder.appendingPathComponent(name) }

    /// An executable `/bin/sh` script.
    @discardableResult
    func script(_ name: String, _ body: String) throws -> String {
        let url = file(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    /// The text of a file once it ends with a newline.
    func wait(for name: String) async throws -> String {
        for _ in 0..<600 {
            if let text = try? String(contentsOf: file(name), encoding: .utf8), text.hasSuffix("\n") {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("no \(name)")
        return ""
    }

    func lines(_ name: String) -> [String] {
        let text = (try? String(contentsOf: file(name), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map(String.init)
    }

    /// True once no process has the pid. A killed process whose parent is
    /// gone is collected by the system a moment later.
    func isGone(_ pid: pid_t) async -> Bool {
        for _ in 0..<400 {
            if kill(pid, 0) == -1 && errno == ESRCH { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return false
    }
}

// MARK: - The parser

final class ShellOutputTests: XCTestCase {
    let marker = "__paddock_env_test__"

    func data(_ text: String) -> Data { Data(text.utf8) }

    // What a real shell prints around the answer: a greeting of its start
    // files, escape codes of a prompt, a logout line.
    func testNoiseBeforeAndAfterTheMarkersIsIgnored() throws {
        let output = data("Last login: Fri Nov 13 08:00:00 on ttys003\n\u{1B}]7;file://mac/Users/demo\u{07}welcome, demo\n"
            + marker + "PATH=/opt/homebrew/bin:/usr/bin\0HOME=/Users/demo\0" + marker
            + "\nSaving session...\n[Process completed]\n")
        let env = try XCTUnwrap(ShellOutput.parse(output, marker: marker))
        XCTAssertEqual(env, ["PATH": "/opt/homebrew/bin:/usr/bin", "HOME": "/Users/demo"])
    }

    // Noise that looks like a variable is still noise.
    func testEntriesOutsideTheMarkersAreNoVariables() throws {
        let output = data("PATH=/from/a/start/file\0EARLY=1\0" + marker + "PATH=/real\0" + marker + "LATE=1\0PATH=/after\0")
        XCTAssertEqual(try XCTUnwrap(ShellOutput.parse(output, marker: marker)), ["PATH": "/real"])
    }

    // The NUL ends an entry, so a value keeps what a line reader would
    // break: newlines, `=` signs, spaces, other alphabets, and nothing.
    func testValuesKeepNewlinesEqualsSignsAndEmptyValues() throws {
        let output = data(marker
            + "MULTI=first line\nsecond line\nFAKE=not a variable\0"
            + "EQUALS=a=b=c\0"
            + "EMPTY=\0"
            + "SPACES=  two  words  \0"
            + "UNICODE=日本語 ü\0"
            + marker)
        let env = try XCTUnwrap(ShellOutput.parse(output, marker: marker))
        XCTAssertEqual(env["MULTI"], "first line\nsecond line\nFAKE=not a variable")
        XCTAssertNil(env["FAKE"], "a line inside a value is no variable")
        XCTAssertEqual(env["EQUALS"], "a=b=c")
        XCTAssertEqual(env["EMPTY"], "")
        XCTAssertEqual(env["SPACES"], "  two  words  ")
        XCTAssertEqual(env["UNICODE"], "日本語 ü")
        XCTAssertEqual(env.count, 5)
    }

    // A NUL inside a value ends the value there. The rest is no
    // `NAME=value`: it is dropped, and the entries next to it stay whole.
    func testANulInsideAValueDoesNotBreakTheOtherEntries() throws {
        let output = data(marker + "BEFORE=1\0BROKEN=head\0tail without a name\0AFTER=2\0\0\0LAST=3" + marker)
        let env = try XCTUnwrap(ShellOutput.parse(output, marker: marker))
        XCTAssertEqual(env, ["BEFORE": "1", "BROKEN": "head", "AFTER": "2", "LAST": "3"])
    }

    // The rest of a value after a NUL can look like an entry. Its name
    // decides: only a real variable name counts, and the first value of a
    // name stays.
    func testOnlyVariableNamesCountAndTheFirstValueStays() throws {
        let output = data(marker
            + "PATH=/first\0"
            + "BASH_FUNC_greet%%=() {  echo hi\n}\0"
            + "1DIGIT=x\0"
            + "has space=x\0"
            + "=no name\0"
            + "PATH=/second\0"
            + "_under_score1=ok\0"
            + marker)
        let env = try XCTUnwrap(ShellOutput.parse(output, marker: marker))
        XCTAssertEqual(env, ["PATH": "/first", "_under_score1": "ok"])
    }

    func testWithoutBothMarkersThereIsNoAnswer() {
        XCTAssertNil(ShellOutput.parse(data("PATH=/usr/bin\0"), marker: marker), "no marker")
        XCTAssertNil(ShellOutput.parse(data("noise" + marker + "PATH=/usr/bin\0"), marker: marker), "the shell died in the middle")
        XCTAssertNil(ShellOutput.parse(Data(), marker: marker))
        XCTAssertNil(ShellOutput.parse(data("PATH=/usr/bin\0"), marker: ""), "an empty marker matches nothing")
        // Both markers and nothing between them: an answer, and an empty one.
        XCTAssertEqual(ShellOutput.parse(data(marker + marker), marker: marker), [:])
    }

    // Bytes that are no UTF-8 do not stop the parser.
    func testBytesThatAreNoTextDoNotStopTheParser() throws {
        var output = Data([0xFF, 0xFE, 0x00])
        output.append(data(marker + "PATH=/usr/bin\0BAD="))
        output.append(Data([0xC3, 0x28, 0x00]))
        output.append(data(marker))
        let env = try XCTUnwrap(ShellOutput.parse(output, marker: marker))
        XCTAssertEqual(env["PATH"], "/usr/bin")
        XCTAssertNotNil(env["BAD"])
    }

    func testEachRunHasItsOwnMarker() {
        let a = ShellProbe.newMarker()
        let b = ShellProbe.newMarker()
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(a.hasPrefix("__paddock_env_"))
        XCTAssertFalse(a.contains("'"), "the marker stands in single quotes in the script")
    }
}

// MARK: - The run of the shell

final class ShellProbeTests: XCTestCase {
    var scratch: Scratch!
    let marker = "__paddock_env_test__"

    override func setUpWithError() throws {
        scratch = try Scratch()
    }

    override func tearDown() {
        scratch.remove()
    }

    func probe(_ shell: String, seconds: Double = 5, maxBytes: Int = 1 << 20) -> ShellProbe {
        ShellProbe(shell: shell, marker: marker, seconds: seconds, maxBytes: maxBytes,
                   environment: ["PATH": "/usr/bin:/bin", "HOME": scratch.folder.path])
    }

    // The fake shell does what a shell does with `-l -i -c SCRIPT`: it
    // reads its start files (here: sets a PATH and prints a greeting) and
    // runs the script.
    func testTheShellRunsAsALoginAndInteractiveShell() async throws {
        let shell = try scratch.script("shell", """
        printf '%s|%s|%s\\n' "$1" "$2" "$3" > '\(scratch.file("flags").path)'
        echo 'greeting of a start file'
        PATH=/opt/homebrew/bin:/Users/demo/.grok/bin:/usr/bin:/bin
        MULTI='one
        two'
        export PATH MULTI
        eval "$4"
        echo 'logout'
        """)
        let result = await probe(shell).run()
        let env = try result.get()
        XCTAssertEqual(env["PATH"], "/opt/homebrew/bin:/Users/demo/.grok/bin:/usr/bin:/bin")
        XCTAssertEqual(env["MULTI"], "one\ntwo")
        XCTAssertEqual(env["HOME"], scratch.folder.path, "the shell starts with the environment of the launcher")
        let flags = try await scratch.wait(for: "flags")
        XCTAssertEqual(flags, "-l|-i|-c")
    }

    func testTheScriptPrintsTheEnvironmentBetweenTheMarkers() {
        let p = ShellProbe(shell: "/bin/zsh", marker: "MARK")
        XCTAssertEqual(p.arguments, ["-l", "-i", "-c", "printf '%s' 'MARK'; /usr/bin/env -0; printf '%s' 'MARK'"])
        XCTAssertEqual(ShellProbe.defaultSeconds, 5)
        XCTAssertEqual(ShellProbe(shell: "/bin/zsh").seconds, 5)
    }

    // Exact bytes: noise, the marker, entries with NUL, the marker, noise.
    func testNoiseAroundTheAnswerOfARealProcess() async throws {
        let shell = try scratch.script("shell", """
        printf 'motd\\nPATH=/noise\\000'
        printf '%s' '\(marker)'
        printf 'PATH=/a:/b\\000MULTI=x\\ny\\000'
        printf '%s' '\(marker)'
        printf 'PATH=/later\\000bye\\n'
        """)
        let env = try await probe(shell).run().get()
        XCTAssertEqual(env, ["PATH": "/a:/b", "MULTI": "x\ny"])
    }

    // A shell that hangs in a start file: the time limit ends the run, and
    // the kill reaches the whole process group, not only the shell.
    func testAHangIsKilledAtTheTimeLimitWithItsProcessGroup() async throws {
        let shell = try scratch.script("shell", """
        sleep 300 &
        echo $! > '\(scratch.file("child.pid").path)'
        echo $$ > '\(scratch.file("shell.pid").path)'
        wait
        """)
        let began = Date()
        let result = await probe(shell, seconds: 1).run()
        let took = Date().timeIntervalSince(began)
        XCTAssertEqual(result, .failure(.timedOut))
        XCTAssertGreaterThanOrEqual(took, 0.9, "the limit is not cut short")
        XCTAssertLessThan(took, 4, "the run ends at the limit, not with the shell")
        let shellPid = pid_t(try await scratch.wait(for: "shell.pid"))!
        let childPid = pid_t(try await scratch.wait(for: "child.pid"))!
        let shellGone = await scratch.isGone(shellPid)
        let childGone = await scratch.isGone(childPid)
        XCTAssertTrue(shellGone, "the hanging shell \(shellPid) still runs")
        XCTAssertTrue(childGone, "the child \(childPid) of the shell still runs: the group was not killed")
    }

    // The shell starts in a session of its own: its process group is not
    // the one of the launcher, so the kill of the group cannot reach the
    // launcher.
    func testTheShellHasItsOwnProcessGroup() async throws {
        let shell = try scratch.script("shell", """
        echo $$ > '\(scratch.file("shell.pid").path)'
        ps -o pgid= -p $$ | tr -d ' ' > '\(scratch.file("pgid").path)'
        eval "$4"
        """)
        _ = try await probe(shell).run().get()
        let pid = try await scratch.wait(for: "shell.pid")
        let group = try await scratch.wait(for: "pgid")
        XCTAssertEqual(group, pid, "the shell leads its own process group")
        XCTAssertNotEqual(pid_t(group), getpgrp())
    }

    // The shell exits, but a process that it started holds the output
    // open and never answers: the limit still ends the run, and the
    // leftover process is killed with the group.
    func testALeftoverProcessCannotHoldTheRun() async throws {
        let shell = try scratch.script("shell", """
        sleep 300 &
        echo $! > '\(scratch.file("child.pid").path)'
        echo 'no answer'
        """)
        let began = Date()
        let result = await probe(shell, seconds: 1).run()
        XCTAssertEqual(result, .failure(.timedOut))
        XCTAssertLessThan(Date().timeIntervalSince(began), 4)
        let childPid = pid_t(try await scratch.wait(for: "child.pid"))!
        let gone = await scratch.isGone(childPid)
        XCTAssertTrue(gone, "the leftover process \(childPid) still runs")
    }

    // The answer is whole, but the shell does not exit (a start file left
    // a job that it waits for). The answer counts at once, and the shell
    // is killed after a moment.
    func testAnAnswerCountsBeforeTheShellExits() async throws {
        let shell = try scratch.script("shell", """
        echo $$ > '\(scratch.file("shell.pid").path)'
        eval "$4"
        sleep 300
        """)
        let began = Date()
        let env = try await probe(shell, seconds: 30).run().get()
        XCTAssertLessThan(Date().timeIntervalSince(began), 5, "the run does not wait for the time limit")
        XCTAssertNotNil(env["PATH"])
        let pid = pid_t(try await scratch.wait(for: "shell.pid"))!
        let gone = await scratch.isGone(pid)
        XCTAssertTrue(gone, "the shell \(pid) still runs")
    }

    func testAShellThatEndsWithoutAnAnswerFails() async throws {
        let broken = try scratch.script("broken", "echo 'syntax error in .zshrc' \nexit 1")
        let brokenResult = await probe(broken).run()
        XCTAssertEqual(brokenResult, .failure(.noAnswer))

        // One marker, then the shell dies.
        let half = try scratch.script("half", "printf '%s' '\(marker)'\nprintf 'PATH=/usr/bin\\000'\nexit 0")
        let halfResult = await probe(half).run()
        XCTAssertEqual(halfResult, .failure(.noAnswer))

        // An answer with no PATH is no answer: it would hide every agent.
        let noPath = try scratch.script("nopath", "printf '%s' '\(marker)'\nprintf 'HOME=/Users/demo\\000'\nprintf '%s' '\(marker)'")
        let noPathResult = await probe(noPath).run()
        XCTAssertEqual(noPathResult, .failure(.noPath))
        let emptyPath = try scratch.script("emptypath", "printf '%s' '\(marker)'\nprintf 'PATH=\\000'\nprintf '%s' '\(marker)'")
        let emptyResult = await probe(emptyPath).run()
        XCTAssertEqual(emptyResult, .failure(.noPath))
    }

    func testAMissingShellFails() async throws {
        let missing = await probe(scratch.file("no-such-shell").path).run()
        XCTAssertEqual(missing, .failure(.notStarted))
        // A file that is no program.
        try "not a program".write(to: scratch.file("plain"), atomically: true, encoding: .utf8)
        let plain = await probe(scratch.file("plain").path).run()
        XCTAssertEqual(plain, .failure(.notStarted))
    }

    func testAFloodIsCutAndKilled() async throws {
        let shell = try scratch.script("shell", """
        echo $$ > '\(scratch.file("shell.pid").path)'
        while :; do printf '%01024d' 0; done
        """)
        let result = await probe(shell, seconds: 30, maxBytes: 64 * 1024).run()
        XCTAssertEqual(result, .failure(.tooLarge))
        let pid = pid_t(try await scratch.wait(for: "shell.pid"))!
        let gone = await scratch.isGone(pid)
        XCTAssertTrue(gone, "the flooding shell \(pid) still runs")
    }

    func testACancelKillsTheShell() async throws {
        let shell = try scratch.script("shell", "echo $$ > '\(scratch.file("shell.pid").path)'\nsleep 300")
        let p = probe(shell, seconds: 60)
        let task = Task { await p.run() }
        let pid = pid_t(try await scratch.wait(for: "shell.pid"))!
        let began = Date()
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result, .failure(.cancelled))
        XCTAssertLessThan(Date().timeIntervalSince(began), 5)
        let gone = await scratch.isGone(pid)
        XCTAssertTrue(gone, "the cancelled shell \(pid) still runs")
    }

    // What the shell writes to stderr, and what it reads, does not count:
    // stdin is empty, so a start file that asks a question gets no answer
    // and goes on.
    func testTheShellHasNoInputAndItsErrorsAreDropped() async throws {
        let shell = try scratch.script("shell", """
        echo 'warning: no job control in this shell' >&2
        read answer
        echo "answer=[$answer]" > '\(scratch.file("answer").path)'
        eval "$4"
        """)
        let env = try await probe(shell).run().get()
        XCTAssertNotNil(env["PATH"])
        let answer = try await scratch.wait(for: "answer")
        XCTAssertEqual(answer, "answer=[]")
    }
}

// MARK: - The filter and the fallback

final class ChildEnvironmentTests: XCTestCase {
    let home = "/Users/demo"

    // The user's shell has much more than paddock needs: only PATH, HOME,
    // LANG and the named set pass.
    func testOnlyThePathAndTheNeededSetPass() {
        let shell = [
            "PATH": "/opt/homebrew/bin:/Users/demo/.local/bin:/usr/bin:/bin",
            "HOME": home,
            "LANG": "de_DE.UTF-8",
            "ANTHROPIC_API_KEY": "sk-ant",
            "OPENAI_API_KEY": "sk-oai",
            "XAI_API_KEY": "xai",
            "HTTPS_PROXY": "http://127.0.0.1:7890",
            "PADDOCK_LOG": "debug",
            // Not for paddock:
            "AWS_SECRET_ACCESS_KEY": "aws",
            "NPM_TOKEN": "npm",
            "STRIPE_API_KEY": "stripe",
            "DATABASE_URL": "postgres://user:password@db/prod",
            "EDITOR": "vim",
            "OLDPWD": "/tmp",
            "SHLVL": "2",
            "TERM_PROGRAM": "Apple_Terminal",
        ]
        let process = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": home, "TMPDIR": "/var/folders/x/T/",
                       "USER": "demo", "__CFBundleIdentifier": "dev.paddock.mac", "XPC_SERVICE_NAME": "application.dev.paddock.mac"]
        let env = LauncherEnvironment.resolved(shell: "/bin/zsh", answer: shell, process: process)
        XCTAssertEqual(env.source, .shell("/bin/zsh"))
        XCTAssertEqual(env.variables, [
            "PATH": "/opt/homebrew/bin:/Users/demo/.local/bin:/usr/bin:/bin",
            "HOME": home,
            "LANG": "de_DE.UTF-8",
            "ANTHROPIC_API_KEY": "sk-ant",
            "OPENAI_API_KEY": "sk-oai",
            "XAI_API_KEY": "xai",
            "HTTPS_PROXY": "http://127.0.0.1:7890",
            "PADDOCK_LOG": "debug",
            "TMPDIR": "/var/folders/x/T/",
            "USER": "demo",
        ])
        XCTAssertEqual(env.path, "/opt/homebrew/bin:/Users/demo/.local/bin:/usr/bin:/bin", "the PATH of the shell, not of launchd")
        XCTAssertTrue(env.isFromShell)
        XCTAssertFalse(env.isFallback)
    }

    func testTheNamesThatPass() {
        for name in ["PATH", "HOME", "LANG", "LC_ALL", "USER", "SHELL", "TMPDIR", "SSH_AUTH_SOCK", "XDG_CONFIG_HOME",
                     "ANTHROPIC_API_KEY", "ANTHROPIC_BASE_URL", "OPENAI_API_KEY", "CODEX_API_KEY", "GEMINI_API_KEY",
                     "GROK_API_KEY", "XAI_API_KEY", "MOONSHOT_API_KEY", "OPENROUTER_API_KEY", "NOUS_API_KEY",
                     "https_proxy", "NO_PROXY", "PADDOCK_BORROW_DIR"] {
            XCTAssertTrue(ChildEnvironment.passes(name), name)
        }
        for name in ["AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "GOOGLE_APPLICATION_CREDENTIALS", "VAULT_TOKEN",
                     "NPM_TOKEN", "HOMEBREW_GITHUB_API_TOKEN", "EDITOR", "PWD", "OLDPWD", "TERM", "DYLD_INSERT_LIBRARIES",
                     "LD_PRELOAD", "PATH_INFO", "MYPADDOCK_X", "paddock_log", ""] {
            XCTAssertFalse(ChildEnvironment.passes(name), name)
        }
    }

    func testTheUsualFoldersInOrder() {
        XCTAssertEqual(FallbackPath.folders(home: home, agents: ["grok", "opencode"]), [
            "/opt/homebrew/bin", "/usr/local/bin",
            "/Users/demo/.local/bin", "/Users/demo/.bun/bin", "/Users/demo/.npm-global/bin", "/Users/demo/.cargo/bin",
            "/Users/demo/.grok/bin", "/Users/demo/.opencode/bin",
            "/Users/demo/.kimi-code/bin",
        ])
        // The folders where the agents of the owner's Mac are.
        let folders = FallbackPath.folders(home: home, agents: FallbackPath.agents)
        for folder in ["/opt/homebrew/bin", "/Users/demo/.local/bin", "/Users/demo/.grok/bin", "/Users/demo/.opencode/bin",
                       "/Users/demo/.kimi-code/bin"] {
            XCTAssertTrue(folders.contains(folder), folder)
        }
        // Every agent of paddock's list has its folder.
        for agent in FallbackPath.agents {
            XCTAssertTrue(folders.contains("/Users/demo/.\(agent)/bin"), agent)
        }
        XCTAssertEqual(Set(folders).count, folders.count, "no folder twice")
    }

    // The agents of the real `paddock list --json` are the agents of the
    // fallback: a new agent of paddock needs no new launcher (`learn`),
    // but the known ones are there from the first look.
    func testTheFallbackKnowsTheAgentsOfTheRealList() throws {
        let data = try Data(contentsOf: Fixtures.root.appendingPathComponent("real-0.2.2/list.json"))
        let listed = try HarnessJSON.list(data).filter { !$0.app }.map(\.name)
        XCTAssertEqual(Set(listed), Set(FallbackPath.agents))
    }

    func testTheFallbackPathKeepsThePathOfTheLauncherAtItsEnd() {
        let path = FallbackPath.path(home: home, agents: ["grok"], inherited: "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin")
        XCTAssertEqual(path, "/opt/homebrew/bin:/usr/local/bin:/Users/demo/.local/bin:/Users/demo/.bun/bin:"
            + "/Users/demo/.npm-global/bin:/Users/demo/.cargo/bin:/Users/demo/.grok/bin:/Users/demo/.kimi-code/bin:"
            + "/usr/bin:/bin:/usr/sbin:/sbin")
        // No PATH at all: the system folders.
        XCTAssertTrue(FallbackPath.path(home: home, agents: [], inherited: nil).hasSuffix(":/usr/bin:/bin:/usr/sbin:/sbin"))
        XCTAssertTrue(FallbackPath.path(home: home, agents: [], inherited: "").hasSuffix(":/usr/bin:/bin:/usr/sbin:/sbin"))
        // No home folder: only the fixed folders.
        XCTAssertEqual(FallbackPath.path(home: "", agents: ["grok"], inherited: "/usr/bin"), "/opt/homebrew/bin:/usr/local/bin:/usr/bin")
    }

    // A name from paddock's answer becomes a folder name: it must not
    // leave the home folder.
    func testAnAgentNameIsOneFolderName() {
        for name in ["grok", "cursor-agent", "kiro-cli", "agent_2", "v1.5"] { XCTAssertTrue(FallbackPath.isAgentName(name), name) }
        for name in ["", ".", "..", "../etc", "a/b", ".hidden", "-flag", "a b", "a:b", "a\nb"] {
            XCTAssertFalse(FallbackPath.isAgentName(name), name)
        }
        XCTAssertEqual(FallbackPath.folders(home: home, agents: ["../../etc", "ok"]).filter { $0.contains("etc") }, [])
    }

    func testTheFallbackEnvironment() {
        let process = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8", "SECRET_THING": "x",
                       "PADDOCK_FAKE_STATE": "/tmp/state"]
        let env = LauncherEnvironment.fallback(shell: "/bin/zsh", reason: .timedOut, process: process, home: home, agents: ["grok"])
        XCTAssertEqual(env.source, .fallback(shell: "/bin/zsh", reason: .timedOut))
        XCTAssertTrue(env.isFallback)
        XCTAssertFalse(env.isFromShell)
        XCTAssertTrue(env.path.hasPrefix("/opt/homebrew/bin:/usr/local/bin:/Users/demo/.local/bin:"))
        XCTAssertTrue(env.path.contains(":/Users/demo/.grok/bin:"))
        XCTAssertTrue(env.path.hasSuffix(":/usr/bin:/bin:/usr/sbin:/sbin"))
        XCTAssertEqual(env.variables["HOME"], home, "paddock needs HOME even when launchd gave none")
        XCTAssertEqual(env.variables["LANG"], "en_US.UTF-8")
        XCTAssertEqual(env.variables["PADDOCK_FAKE_STATE"], "/tmp/state")
        XCTAssertNil(env.variables["SECRET_THING"])
    }

    func testWhichShellIsAsked() {
        XCTAssertEqual(ShellEnvironment.shellPath(chosen: nil, environment: ["SHELL": "/opt/homebrew/bin/fish"]), "/opt/homebrew/bin/fish")
        XCTAssertEqual(ShellEnvironment.shellPath(chosen: nil, environment: [:]), "/bin/zsh")
        XCTAssertEqual(ShellEnvironment.shellPath(chosen: "", environment: ["SHELL": "/bin/bash"]), "/bin/bash")
        XCTAssertEqual(ShellEnvironment.shellPath(chosen: "  /bin/bash \n", environment: ["SHELL": "/bin/zsh"]), "/bin/bash",
                       "the shell of Settings comes first")
        XCTAssertEqual(ShellEnvironment.shellPath(chosen: "bash", environment: ["SHELL": "zsh"]), "/bin/zsh", "only a full path counts")
    }
}

// MARK: - The cache of the session

/// Counts the runs of the "shell" and gives the answers in turn.
final class FakeShell: @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [Result<[String: String], ShellFailure>]
    private var asked: [String] = []
    /// Seconds each answer takes, by its number.
    var delays: [Double] = []

    init(_ answers: [Result<[String: String], ShellFailure>]) {
        self.answers = answers
    }

    var shells: [String] {
        lock.lock()
        defer { lock.unlock() }
        return asked
    }

    func ask(_ shell: String) async -> Result<[String: String], ShellFailure> {
        lock.lock()
        let index = asked.count
        asked.append(shell)
        let answer = answers[min(index, answers.count - 1)]
        let delay = index < delays.count ? delays[index] : 0
        lock.unlock()
        if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        return answer
    }
}

final class ShellEnvironmentCacheTests: XCTestCase {
    let home = "/Users/demo"
    let finder = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": "/Users/demo", "SHELL": "/bin/zsh"]
    let userPath = "/opt/homebrew/bin:/Users/demo/.local/bin:/Users/demo/.grok/bin:/usr/bin:/bin"

    func make(_ shell: FakeShell) -> ShellEnvironment {
        let finder = self.finder
        return ShellEnvironment(process: { finder }, home: home, ask: { await shell.ask($0) })
    }

    // Before the shell answered, the children get the launcher's own
    // environment, filtered.
    func testBeforeTheFirstAnswerTheEnvironmentIsTheLaunchersOwn() {
        let env = make(FakeShell([.failure(.timedOut)])).current
        XCTAssertEqual(env.source, .inherited)
        XCTAssertEqual(env.path, "/usr/bin:/bin:/usr/sbin:/sbin")
    }

    func testTheShellIsAskedOncePerSession() async {
        let shell = FakeShell([.success(["PATH": userPath, "HOME": home])])
        let cache = make(shell)
        let first = await cache.resolve()
        let second = await cache.resolve()
        let third = await cache.resolve()
        XCTAssertEqual(shell.shells, ["/bin/zsh"], "one run of the shell for the session")
        XCTAssertEqual(first.path, userPath)
        XCTAssertEqual(second, first)
        XCTAssertEqual(third, first)
        XCTAssertEqual(cache.current, first)
    }

    // Check Again and Look again: the shell is asked again, and its new
    // answer replaces the old one.
    func testARefreshAsksTheShellAgain() async {
        let shell = FakeShell([.success(["PATH": "/usr/bin"]), .success(["PATH": userPath])])
        let cache = make(shell)
        await cache.resolve()
        XCTAssertEqual(cache.current.path, "/usr/bin")
        let next = await cache.refresh()
        XCTAssertEqual(shell.shells.count, 2)
        XCTAssertEqual(next.path, userPath)
        XCTAssertEqual(cache.current.path, userPath, "an agent installed since the start is found")
        await cache.resolve()
        XCTAssertEqual(shell.shells.count, 2, "the new answer is cached again")
    }

    // A change of the shell in Settings: the next run asks that shell.
    func testTheShellOfSettingsIsAsked() async {
        let shell = FakeShell([.success(["PATH": userPath])])
        let cache = make(shell)
        await cache.resolve()
        let next = await cache.refresh(chosen: "/opt/homebrew/bin/fish")
        XCTAssertEqual(shell.shells, ["/bin/zsh", "/opt/homebrew/bin/fish"])
        XCTAssertEqual(next.source, .shell("/opt/homebrew/bin/fish"))
    }

    func testAShellThatFailsGivesTheUsualFolders() async {
        for reason in [ShellFailure.timedOut, .noAnswer, .notStarted, .tooLarge, .noPath] {
            let cache = make(FakeShell([.failure(reason)]))
            let env = await cache.resolve()
            XCTAssertEqual(env.source, .fallback(shell: "/bin/zsh", reason: reason))
            XCTAssertTrue(env.isFallback)
            XCTAssertTrue(env.path.hasPrefix("/opt/homebrew/bin:/usr/local/bin:/Users/demo/.local/bin:/Users/demo/.bun/bin:"
                + "/Users/demo/.npm-global/bin:/Users/demo/.cargo/bin:/Users/demo/.agy/bin:"), env.path)
            XCTAssertTrue(env.path.contains(":/Users/demo/.grok/bin:"))
            XCTAssertTrue(env.path.hasSuffix(":/usr/bin:/bin:/usr/sbin:/sbin"))
        }
    }

    // The fallback is cached too, and a later good answer replaces it.
    func testTheFallbackEndsWhenTheShellAnswers() async {
        let shell = FakeShell([.failure(.timedOut), .success(["PATH": userPath])])
        let cache = make(shell)
        await cache.resolve()
        await cache.resolve()
        XCTAssertEqual(shell.shells.count, 1)
        XCTAssertTrue(cache.current.isFallback)
        await cache.refresh()
        XCTAssertEqual(cache.current.source, .shell("/bin/zsh"))
        XCTAssertEqual(cache.current.path, userPath)
    }

    // Two runs overlap (Check Again twice): the answer of the later run
    // stays, also when the earlier run ends last.
    func testOfTwoOverlappingRunsTheLaterOneStays() async {
        let shell = FakeShell([.success(["PATH": "/slow/first"]), .success(["PATH": "/quick/second"])])
        shell.delays = [0.5, 0]
        let cache = make(shell)
        async let first = cache.refresh()
        try? await Task.sleep(nanoseconds: 100_000_000)
        let second = await cache.refresh()
        let firstResult = await first
        XCTAssertEqual(second.path, "/quick/second")
        XCTAssertEqual(firstResult.path, "/quick/second", "the earlier run gives the current environment")
        XCTAssertEqual(cache.current.path, "/quick/second")
    }

    // The fallback PATH has a folder for each agent that paddock knows:
    // an agent that this launcher never heard of gets its folder when
    // paddock lists it.
    func testANewAgentOfPaddockWidensTheFallback() async {
        let cache = make(FakeShell([.failure(.timedOut)]))
        await cache.resolve()
        XCTAssertFalse(cache.current.path.contains("/.newagent/bin"))
        XCTAssertFalse(cache.learn(agents: ["claude", "codex"]), "known agents change nothing")
        XCTAssertTrue(cache.learn(agents: ["claude", "newagent", "../evil"]))
        XCTAssertTrue(cache.current.path.contains(":/Users/demo/.newagent/bin:"))
        XCTAssertFalse(cache.current.path.contains("evil"))
        XCTAssertTrue(cache.current.path.hasSuffix(":/usr/bin:/bin:/usr/sbin:/sbin"))
        XCTAssertFalse(cache.learn(agents: ["newagent"]), "the second time changes nothing")
        // The name stays for a later fallback.
        await cache.refresh()
        XCTAssertTrue(cache.current.path.contains(":/Users/demo/.newagent/bin:"))
    }

    // The PATH of the shell is the user's: paddock's list does not change it.
    func testAGoodAnswerIsNotWidened() async {
        let cache = make(FakeShell([.success(["PATH": userPath])]))
        await cache.resolve()
        XCTAssertFalse(cache.learn(agents: ["newagent"]))
        XCTAssertEqual(cache.current.path, userPath)
    }

    // The app under a UI test asks no shell.
    func testWithoutAShellTheEnvironmentStaysTheLaunchersOwn() async {
        let finder = self.finder
        let cache = ShellEnvironment(process: { finder }, home: home, ask: nil)
        let env = await cache.resolve()
        XCTAssertEqual(env.source, .inherited)
        XCTAssertEqual(env.path, "/usr/bin:/bin:/usr/sbin:/sbin")
        let again = await cache.refresh()
        XCTAssertEqual(again.source, .inherited)
    }

    // The whole way with a process: a "shell" that hangs gives the usual
    // folders after the time limit.
    func testAHangingShellProcessGivesTheUsualFolders() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let shell = try scratch.script("shell", "sleep 300")
        let process = ["PATH": "/usr/bin:/bin", "SHELL": shell]
        let cache = ShellEnvironment(process: { process }, home: home, ask: { path in
            await ShellProbe(shell: path, seconds: 0.5, environment: process).run()
        })
        let began = Date()
        let env = await cache.resolve()
        XCTAssertLessThan(Date().timeIntervalSince(began), 4)
        XCTAssertEqual(env.source, .fallback(shell: shell, reason: .timedOut))
        XCTAssertTrue(env.path.hasPrefix("/opt/homebrew/bin:/usr/local/bin:/Users/demo/.local/bin:"))
    }
}

// MARK: - Every call gets the PATH

/// A fake paddock for the PATH checks. It logs the PATH of each call and
/// finds its agents as paddock does: by a look into the folders of PATH.
enum PathPaddock {
    /// `list --json` names `codex` and `grok`; each is installed when PATH
    /// has a program of that name. Other calls go to the fake paddock.
    static func script(log: String, fake: String) -> String {
        """
        printf '%s\\t%s\\t%s\\n' "$PATH" "${SECRET_OF_THE_SHELL-unset}" "$*" >> '\(log)'
        entry() {
          found=$(command -v "$1" 2>/dev/null)
          if [ -n "$found" ]; then
            printf '{"app":false,"description":"%s","exe":"%s","installed":true,"name":"%s"}' "$2" "$found" "$1"
          else
            printf '{"app":false,"description":"%s","exe":null,"installed":false,"name":"%s"}' "$2" "$1"
          fi
        }
        if [ "$*" = "list --json" ]; then
          printf '{"api_version":"paddock.list/v1","harnesses":['
          entry codex 'OpenAI Codex CLI'
          printf ','
          entry grok 'xAI Grok Build'
          printf ']}\\n'
          exit 0
        fi
        exec '\(fake)' "$@"
        """
    }
}

final class ResolvedPathCallTests: XCTestCase {
    var scratch: Scratch!
    /// The PATH of an app that Finder started.
    static let finderPath = "/usr/bin:/bin:/usr/sbin:/sbin"

    override func setUpWithError() throws {
        scratch = try Scratch()
        setenv("PADDOCK_FAKE_STATE", scratch.file("state").path, 1)
        setenv("PADDOCK_FAKE_SCENARIO", Fixtures.scenario("agents").path, 1)
    }

    override func tearDown() {
        unsetenv("PADDOCK_FAKE_STATE")
        unsetenv("PADDOCK_FAKE_SCENARIO")
        unsetenv("SECRET_OF_THE_SHELL")
        scratch.remove()
    }

    /// A paddock that logs its PATH, and the folders of two agents.
    func makePaddock() throws -> String {
        try scratch.script("homebrew/bin/codex", "exit 0")
        try scratch.script("home/.grok/bin/grok", "exit 0")
        return try scratch.script("paddock", PathPaddock.script(log: scratch.file("env.log").path, fake: BoundedRunTests.fake))
    }

    /// The PATH of the user's shell: the agent folders first.
    var userPath: String {
        scratch.file("homebrew/bin").path + ":" + scratch.file("home/.grok/bin").path + ":" + ResolvedPathCallTests.finderPath
    }

    /// The PATH and the arguments of each logged call.
    var logged: [(path: String, secret: String, args: String)] {
        scratch.lines("env.log").map { line in
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            return (parts[0], parts.count > 1 ? parts[1] : "", parts.count > 2 ? parts[2] : "")
        }
    }

    // The three ways `ProcessRunner` starts paddock: a plain run, a
    // bounded run and a stream.
    func testEachKindOfRunGetsTheEnvironment() async throws {
        let paddock = try makePaddock()
        let path = userPath
        let runner = ProcessRunner(executable: paddock, environment: { ["PATH": path, "PADDOCK_FAKE_STATE": "x"] })
        _ = try await runner.run(["list", "--json"])
        _ = try await runner.run(["list", "--json"], limits: RunLimits(seconds: 10, maxBytes: 64 * 1024))
        var lines: [String] = []
        for try await line in runner.lines(["list", "--json"]) { lines.append(line) }
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(logged.map(\.path), [path, path, path])
    }

    // The bug of the owner's Mac, and its fix, with real processes: the
    // same paddock finds no agent with the PATH of Finder, and both
    // agents with the PATH of the user's shell.
    func testPaddockFindsTheAgentsOfTheShellPath() async throws {
        let paddock = try makePaddock()
        // The shell of the user: its start files put the agent folders in PATH.
        let shell = try scratch.script("shell", """
        PATH='\(userPath)'
        SECRET_OF_THE_SHELL=do-not-pass
        export PATH SECRET_OF_THE_SHELL
        eval "$4"
        """)
        let finder = ["PATH": ResolvedPathCallTests.finderPath, "HOME": scratch.file("home").path, "SHELL": shell]

        // Before: paddock gets the PATH of Finder.
        let before = ProcessRunner(executable: paddock, environment: { finder })
        let none = try HarnessJSON.list(try await before.run(AgentArgs.list).stdout)
        XCTAssertEqual(none.map(\.installed), [false, false], "with the PATH of Finder paddock finds no agent")

        // After: the launcher asks the shell and passes its PATH.
        let cache = ShellEnvironment(process: { finder }, home: scratch.file("home").path, ask: { path in
            await ShellProbe(shell: path, environment: finder).run()
        })
        let env = await cache.resolve()
        XCTAssertEqual(env.source, .shell(shell))
        XCTAssertEqual(env.path, userPath)
        let runner = ProcessRunner(executable: paddock, environment: { cache.current.variables })
        let found = try HarnessJSON.list(try await runner.run(AgentArgs.list).stdout)
        XCTAssertEqual(found.map(\.name), ["codex", "grok"])
        XCTAssertEqual(found.map(\.installed), [true, true])
        XCTAssertEqual(found.map(\.exe), [scratch.file("homebrew/bin/codex").path, scratch.file("home/.grok/bin/grok").path])

        // Check this Mac: each agent with its path, none missing.
        let checks = WelcomeChecks.agents(found)
        XCTAssertEqual(checks.map(\.installed), [true, true])
        XCTAssertEqual(checks.map { $0.shownPath(home: scratch.file("home").path) },
                       [scratch.file("homebrew/bin/codex").path, "~/.grok/bin/grok"])

        // The shell had a secret: paddock did not get it.
        XCTAssertEqual(Set(logged.map(\.secret)), ["unset"])
        XCTAssertNil(env.variables["SECRET_OF_THE_SHELL"])
    }

    // The shell does not answer: the usual folders still find an agent in
    // `~/.grok/bin`.
    func testTheFallbackFindsAnAgentInItsOwnFolder() async throws {
        let paddock = try makePaddock()
        let shell = try scratch.script("shell", "sleep 300")
        let home = scratch.file("home").path
        let finder = ["PATH": ResolvedPathCallTests.finderPath, "HOME": home, "SHELL": shell]
        let cache = ShellEnvironment(process: { finder }, home: home, ask: { path in
            await ShellProbe(shell: path, seconds: 0.5, environment: finder).run()
        })
        let env = await cache.resolve()
        XCTAssertTrue(env.isFallback)
        let runner = ProcessRunner(executable: paddock, environment: { cache.current.variables })
        let found = try HarnessJSON.list(try await runner.run(AgentArgs.list).stdout)
        let grok = try XCTUnwrap(found.first { $0.name == "grok" })
        XCTAssertTrue(grok.installed, "the fallback has ~/.grok/bin")
        XCTAssertEqual(grok.exe, scratch.file("home/.grok/bin/grok").path)
    }

    // The runner reads the environment at each call: after Check Again
    // the same service uses the new PATH.
    func testARefreshReachesTheNextCall() async throws {
        let paddock = try makePaddock()
        let shell = FakeShell([.success(["PATH": ResolvedPathCallTests.finderPath]), .success(["PATH": userPath])])
        let finder = ["PATH": ResolvedPathCallTests.finderPath]
        let cache = ShellEnvironment(process: { finder }, home: scratch.file("home").path, ask: { await shell.ask($0) })
        let service = CLIPaddockService(runner: ProcessRunner(executable: paddock, environment: { cache.current.variables }))
        await cache.resolve()
        let first = try HarnessJSON.list(try await service.raw(AgentArgs.list).stdout)
        XCTAssertEqual(first.filter(\.installed).count, 0)
        await cache.refresh()
        let second = try HarnessJSON.list(try await service.raw(AgentArgs.list).stdout)
        XCTAssertEqual(second.filter(\.installed).count, 2, "the agents show after Look again")
    }

    // Without an environment of its own the runner passes the launcher's:
    // the tests of the fake paddock keep their variables.
    func testARunnerWithoutAnEnvironmentInheritsTheLaunchers() async throws {
        let paddock = try makePaddock()
        setenv("SECRET_OF_THE_SHELL", "inherited", 1)
        _ = try await ProcessRunner(executable: paddock).run(["list", "--json"])
        XCTAssertEqual(logged.map(\.secret), ["inherited"])
    }
}

/// The process of a pane: it keeps the command.
@MainActor
final class RecordingProcess: AgentProcess {
    var command: AgentCommand?
    var onExit: ((Int32?) -> Void)?

    func start(_ command: AgentCommand) { self.command = command }
    func terminate() {}
}

/// The launcher as a whole: the binary check, the snapshots, the event
/// stream, the agent reads and the panes.
@MainActor
final class EveryCallPathTests: XCTestCase {
    var scratch: Scratch!

    override func setUp() async throws {
        scratch = try Scratch()
        setenv("PADDOCK_FAKE_STATE", scratch.file("state").path, 1)
        setenv("PADDOCK_FAKE_SCENARIO", Fixtures.scenario("agents").path, 1)
        setenv("SECRET_OF_THE_SHELL", "from-the-launcher", 1)
    }

    override func tearDown() async throws {
        unsetenv("PADDOCK_FAKE_STATE")
        unsetenv("PADDOCK_FAKE_SCENARIO")
        unsetenv("SECRET_OF_THE_SHELL")
        scratch.remove()
    }

    final class Processes {
        var list: [RecordingProcess] = []
    }

    // Every paddock call of a start, of the agent reads and of an action
    // has the PATH of the shell, and none has a variable outside the set.
    func testEveryPaddockCallGetsTheResolvedPath() async throws {
        let paddock = try scratch.script("paddock", PathPaddock.script(log: scratch.file("env.log").path, fake: BoundedRunTests.fake))
        let userPath = scratch.file("homebrew/bin").path + ":/usr/bin:/bin:/usr/sbin:/sbin"
        try scratch.script("homebrew/bin/codex", "exit 0")
        let shell = FakeShell([.success(["PATH": userPath, "SECRET_OF_THE_SHELL": "from-the-shell", "ANTHROPIC_API_KEY": "sk-ant"])])
        let cache = ShellEnvironment(home: scratch.file("home").path, ask: { await shell.ask($0) })
        await cache.resolve()

        let store = LauncherStore(service: nil)
        await store.start(locate: { paddock }, makeService: { path in
            CLIPaddockService(runner: ProcessRunner(executable: path, environment: { cache.current.variables }))
        })
        XCTAssertTrue(store.binary.isUsable, "\(store.binary)")
        let processes = Processes()
        let agents = AgentStore(launcher: store, paddockPath: { paddock }, makeProcess: { _ in
            let process = RecordingProcess()
            processes.list.append(process)
            return process
        })
        agents.use(cache.current)
        await agents.loadChoices()
        await agents.refreshRuns(force: true)
        await store.reloadApprovals()
        _ = try? await store.service?.execute(AgentArgs.stop("claude-1a2b3c"))
        // The event stream is a child too.
        await waitUntil { self.scratch.lines("env.log").contains { $0.hasSuffix("\tevents --follow --json") || $0.hasSuffix("\tevents --follow --json --notify") } }
        store.stopEvents()

        let lines = scratch.lines("env.log").map { $0.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init) }
        // paddock 0.2.4 lists notices-v1: the stream asks for the notices.
        let calls = lines.map { $0[2] == "events --follow --json --notify" ? "events --follow --json" : $0[2] }
        for expected in ["--version", "--launcher-protocol", "app list --json", "macvm status --json", "approvals --json",
                         "events --follow --json", "list --json", "run --help", "recent --json", "ps --json", "board --json",
                         "stop claude-1a2b3c"] {
            XCTAssertTrue(calls.contains(expected), "no call \(expected) in \(calls)")
        }
        XCTAssertGreaterThanOrEqual(lines.count, 12)
        for line in lines {
            XCTAssertEqual(line[0], userPath, "the call `\(line[2])` did not get the PATH of the shell")
            XCTAssertEqual(line[1], "unset", "the call `\(line[2])` got a variable that is not in the set")
        }
        // paddock found the agent of the shell's PATH.
        XCTAssertEqual(agents.harnesses.first { $0.name == "codex" }?.exe, scratch.file("homebrew/bin/codex").path)

        // The pane: paddock itself, with the same environment.
        let key = try XCTUnwrap(agents.start(AgentLaunch(harness: "codex", folder: scratch.folder.path)))
        XCTAssertNotNil(agents.room(key))
        let command = try XCTUnwrap(processes.list.last?.command)
        XCTAssertEqual(command.executable, paddock, "the environment is the shell's: no second shell")
        XCTAssertEqual(command.args, ["run", "--quiet", "codex", "--network", "api", agents.manualFlag])
        XCTAssertTrue(command.environment.contains("PATH=" + userPath))
        XCTAssertTrue(command.environment.contains("ANTHROPIC_API_KEY=sk-ant"), "the login variable of an agent passes")
        XCTAssertTrue(command.environment.contains("TERM=xterm-256color"))
        XCTAssertFalse(command.environment.contains { $0.hasPrefix("SECRET_OF_THE_SHELL=") })
        let names = Set(command.environment.map { String($0.split(separator: "=", maxSplits: 1)[0]) })
        for name in names where !["TERM", "COLORTERM", "LANG"].contains(name) {
            XCTAssertTrue(ChildEnvironment.passes(name), "the pane got \(name)")
        }
    }

    // The panes with the three kinds of environment.
    func testThePaneCommandFollowsTheEnvironment() async throws {
        let h = try await Harness("agents")
        let processes = Processes()
        let agents = AgentStore(launcher: h.store, environment: ["PATH": "/usr/bin"], paddockPath: { "/opt/homebrew/bin/paddock" },
                                makeProcess: { _ in
            let process = RecordingProcess()
            processes.list.append(process)
            return process
        })
        let launch = AgentLaunch(harness: "claude", folder: "/Users/demo/src/shop", mode: .auto)

        // The shell answered: paddock starts as it is.
        let resolved = LauncherEnvironment.resolved(shell: "/bin/zsh", answer: ["PATH": "/opt/homebrew/bin:/usr/bin", "EDITOR": "vim"],
                                                    process: ["HOME": "/Users/demo"])
        agents.use(resolved)
        XCTAssertEqual(agents.environmentSource, .shell("/bin/zsh"))
        XCTAssertFalse(agents.usesFallbackPath)
        agents.start(launch)
        var command = try XCTUnwrap(processes.list.last?.command)
        XCTAssertEqual(command.executable, "/opt/homebrew/bin/paddock")
        XCTAssertEqual(command.args, ["run", "--quiet", "claude", "--network", "api"])
        XCTAssertEqual(command.directory, "/Users/demo/src/shop")
        XCTAssertEqual(command.environment.sorted(), ["COLORTERM=truecolor", "HOME=/Users/demo", "LANG=en_US.UTF-8",
                                                     "PATH=/opt/homebrew/bin:/usr/bin", "TERM=xterm-256color"])

        // The shell did not answer: the login shell gets one more chance
        // in the pane, with the usual folders as its PATH.
        let fallback = LauncherEnvironment.fallback(shell: "/bin/zsh", reason: .timedOut, process: ["PATH": "/usr/bin", "SHELL": "/bin/zsh"],
                                                    home: "/Users/demo", agents: ["grok"])
        agents.use(fallback)
        XCTAssertTrue(agents.usesFallbackPath)
        agents.start(launch)
        command = try XCTUnwrap(processes.list.last?.command)
        XCTAssertEqual(command.executable, "/bin/zsh")
        XCTAssertEqual(command.args, ["-l", "-c", #"exec "$0" "$@""#, "/opt/homebrew/bin/paddock", "run", "--quiet", "claude", "--network", "api"])
        XCTAssertTrue(command.environment.contains("PATH=" + fallback.path))
        XCTAssertTrue(fallback.path.contains("/Users/demo/.grok/bin"))

        // A view of a run takes the same way.
        agents.use(resolved)
        await agents.refreshRuns(force: true)
        let room = try XCTUnwrap(agents.rooms.first { $0.runID != nil })
        agents.reopen(room)
        command = try XCTUnwrap(processes.list.last?.command)
        XCTAssertEqual(command.executable, "/opt/homebrew/bin/paddock")
        XCTAssertEqual(command.args.first, "view")
        XCTAssertTrue(command.environment.contains("PATH=/opt/homebrew/bin:/usr/bin"))
    }

    // With the fallback PATH, an agent name that is new to the launcher
    // widens the PATH, and paddock looks once more.
    func testANewAgentNameReadsTheListOnceMore() async throws {
        let h = try await Harness("agents")
        let agents = AgentStore(launcher: h.store, makeProcess: { _ in RecordingProcess() })
        let before = h.calls(AgentArgs.list).count
        var names: [[String]] = []
        var answers = [true, false]
        agents.agentsListed = { listed in
            names.append(listed)
            return answers.removeFirst()
        }
        await agents.loadChoices()
        XCTAssertEqual(h.calls(AgentArgs.list).count, before + 2, "the list is read again with the wider PATH")
        XCTAssertEqual(names.count, 1, "and only once more")
        XCTAssertEqual(names.first, ["claude", "codex", "copilot", "gemini", "grok", "kimi", "opencode"], "the agents, not the desktop apps")
        XCTAssertFalse(agents.harnesses.isEmpty)

        // Nothing new: one read.
        await agents.loadChoices()
        XCTAssertEqual(h.calls(AgentArgs.list).count, before + 3)
    }

    // No hook, as in every other test: one read of the list.
    func testWithoutTheHookTheListIsReadOnce() async throws {
        let h = try await Harness("agents")
        let agents = AgentStore(launcher: h.store, makeProcess: { _ in RecordingProcess() })
        let before = h.calls(AgentArgs.list).count
        await agents.loadChoices()
        XCTAssertEqual(h.calls(AgentArgs.list).count, before + 1)
        XCTAssertEqual(agents.environmentSource, .inherited)
        XCTAssertTrue(agents.paneThroughShell)
    }
}

// MARK: - No call without the environment

/// The code of the launcher, read as text: every way to paddock takes the
/// environment of the shell.
final class EnvironmentWiringTests: XCTestCase {
    static let root = Fixtures.root.deletingLastPathComponent()

    func swiftFiles(_ folder: String) -> [URL] {
        let walker = FileManager.default.enumerator(at: EnvironmentWiringTests.root.appendingPathComponent(folder),
                                                    includingPropertiesForKeys: nil)
        return (walker?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
    }

    // The app makes its runners with the environment: a runner without
    // one would run paddock with the PATH of Finder again.
    func testEveryRunnerOfTheAppHasTheEnvironment() throws {
        var runners = 0
        for file in swiftFiles("App") {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (number, line) in text.components(separatedBy: "\n").enumerated() where line.contains("ProcessRunner(") {
                runners += 1
                XCTAssertTrue(line.contains("environment: { shell.current.variables }"),
                              "\(file.lastPathComponent):\(number + 1): a ProcessRunner without the environment of the shell")
            }
        }
        XCTAssertGreaterThanOrEqual(runners, 1, "the app has a runner")
    }

    // `ProcessRunner` starts paddock in three places. Each sets the
    // environment of the child.
    func testEveryChildOfTheRunnerGetsTheEnvironment() throws {
        let url = EnvironmentWiringTests.root.appendingPathComponent("PaddockKit/Sources/PaddockKit/Runner.swift")
        let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
        var starts = 0
        for (index, line) in lines.enumerated() where line.contains("= Process()") {
            starts += 1
            let next = lines[index..<min(index + 5, lines.count)].joined(separator: "\n")
            XCTAssertTrue(next.contains("if let environment { process.environment = environment }"),
                          "Runner.swift:\(index + 1): a child without the environment")
        }
        XCTAssertEqual(starts, 3)
    }

    // The shell is asked before the first paddock call of a start, and
    // again on Check Again, Look again and a new shell in Settings.
    func testTheShellIsAskedBeforePaddock() throws {
        let container = try String(contentsOf: EnvironmentWiringTests.root.appendingPathComponent("App/AppContainer.swift"), encoding: .utf8)
        let check = try XCTUnwrap(container.range(of: "static func checkAgain() async {"))
        let body = container[check.upperBound...]
        let resolve = try XCTUnwrap(body.range(of: "await resolveEnvironment()"))
        let start = try XCTUnwrap(body.range(of: "await store.start("))
        XCTAssertLessThan(resolve.lowerBound, start.lowerBound, "the shell comes before the paddock check")
        XCTAssertTrue(container.contains("shellEnvironment.refresh(chosen: LauncherDefaults.shellPath)"))

        let welcome = try String(contentsOf: EnvironmentWiringTests.root.appendingPathComponent("App/Views/OnboardingView.swift"), encoding: .utf8)
        XCTAssertTrue(welcome.contains("await AppContainer.lookAgain()"), "Look again asks the shell again")
        XCTAssertTrue(welcome.contains("WelcomeCopy.shellFallback"), "Check this Mac has the line of the fallback")
        let settings = try String(contentsOf: EnvironmentWiringTests.root.appendingPathComponent("App/Views/SettingsView.swift"), encoding: .utf8)
        XCTAssertTrue(settings.contains(".onChange(of: shellPath)"), "a new shell in Settings is asked at once")
    }
}

// MARK: - Check this Mac

final class AgentPathCheckTests: XCTestCase {
    // Each agent that paddock found shows where it is.
    func testEachInstalledAgentHasItsPath() throws {
        let agents = WelcomeChecks.agents(try HarnessJSON.list(try Fixtures.data("list-agents.json")))
        let claude = try XCTUnwrap(agents.first { $0.harness == "claude" })
        XCTAssertEqual(claude.path, "/Users/demo/.local/bin/claude")
        XCTAssertEqual(claude.shownPath(home: "/Users/demo"), "~/.local/bin/claude")
        XCTAssertEqual(agents.first { $0.harness == "codex" }?.shownPath(home: "/Users/demo"), "/opt/homebrew/bin/codex")
        for agent in agents {
            XCTAssertEqual(agent.path != nil, agent.installed, agent.harness)
        }
    }

    // The list of the owner's Mac, with the PATH of the shell: the agents
    // that paddock found with their paths, then every agent that paddock
    // knows and did not find.
    func testTheRealListShowsFoundAndMissingAgents() throws {
        let data = try Data(contentsOf: Fixtures.root.appendingPathComponent("real-0.2.2/list.json"))
        let agents = WelcomeChecks.agents(try HarnessJSON.list(data))
        let found = agents.filter(\.installed)
        XCTAssertEqual(found.map(\.harness), ["codex", "agy"])
        XCTAssertEqual(found.map(\.path), ["/opt/homebrew/Caskroom/codex/0.166.0/bin/codex",
                                           "/opt/homebrew/Caskroom/antigravity-cli/1.4.12,4768735748292608/antigravity"])
        let missing = agents.filter { !$0.installed }
        XCTAssertEqual(missing.count, 23)
        XCTAssertEqual(Array(agents.prefix(2)), found, "the found agents come first")
        for agent in missing {
            XCTAssertNil(agent.path)
            XCTAssertTrue(agent.result.english.hasPrefix("Not installed."), agent.harness)
        }
        // The install line of the agents whose command the launcher knows.
        XCTAssertEqual(missing.first { $0.harness == "claude" }?.install, "npm install -g @anthropic-ai/claude-code")
        XCTAssertEqual(missing.first { $0.harness == "amp" }?.install, "npm install -g @sourcegraph/amp")
        XCTAssertEqual(missing.first { $0.harness == "qwen" }?.install, "npm install -g @qwen-code/qwen-code")
    }

    func testTheWordsOfTheFallbackAndOfLookAgain() {
        XCTAssertEqual(WelcomeCopy.shellFallback.english, "Your shell did not answer, so paddock for Mac uses the usual folders.")
        XCTAssertEqual(WelcomeCopy.lookAgain.english, "After you install an agent, click Look again.")
        XCTAssertEqual(ShellCopy.status(.shell("/bin/zsh")).english, "paddock for Mac finds the agents with the PATH of /bin/zsh.")
        XCTAssertEqual(ShellCopy.status(.fallback(shell: "/bin/zsh", reason: .timedOut)), WelcomeCopy.shellFallback)
    }
}
