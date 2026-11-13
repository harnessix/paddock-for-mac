import XCTest

/// The PATH of the user's shell in Check this Mac. The "shell" of each
/// test is a small script (PADDOCK_LAUNCHER_SHELL): no test runs the shell
/// of the person at the Mac.
final class ShellPathUITests: XCTestCase {
    var scratch: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("paddock-shell-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch.appendingPathComponent("bin"), withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
    }

    /// An executable `/bin/sh` script in the scratch folder.
    @discardableResult
    private func script(_ name: String, _ body: String) throws -> String {
        let url = scratch.appendingPathComponent(name)
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    /// Goes from step 1 to step 2 of the welcome window.
    private func toCheckStep(_ app: XCUIApplication) {
        let next = app.buttons["onboarding-continue"]
        XCTAssertTrue(next.waitForExistence(timeout: 10))
        next.click()
    }

    /// A paddock that finds `codex` and `grok` as paddock does, by a look
    /// into the folders of PATH, and logs the PATH of each call. Every
    /// other call goes to the fake paddock.
    private func pathPaddock() throws -> String {
        let fake = Fake.launcherRoot.appendingPathComponent("FakePaddock/fake-paddock").path
        return try script("paddock", """
        printf '%s\\n' "$PATH" >> '\(scratch.appendingPathComponent("path.log").path)'
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
        """)
    }

    private var loggedPaths: Set<String> {
        let text = (try? String(contentsOf: scratch.appendingPathComponent("path.log"), encoding: .utf8)) ?? ""
        return Set(text.split(separator: "\n").map(String.init))
    }

    // The bug of the first Mac: the app has the PATH of Finder, the agents
    // are in a folder of the shell's PATH. Check this Mac lists the agent
    // that paddock finds there with its path, and the one that it does
    // not find with Look again.
    func testAgentsOfTheShellPathShowWithTheirPaths() throws {
        let bin = scratch.appendingPathComponent("bin").path
        let userPath = bin + ":/usr/bin:/bin:/usr/sbin:/sbin"
        let codex = try script("bin/codex", "exit 0")
        let shell = try script("shell", """
        echo 'greeting of a start file'
        PATH='\(userPath)'
        export PATH
        eval "$4"
        """)
        let paddock = try pathPaddock()
        let fake = Fake("fresh", binary: paddock, env: ["PADDOCK_LAUNCHER_SHELL": shell])
        let app = fake.launch()
        toCheckStep(app)

        XCTAssertTrue(app.element("welcome-agent-codex").waitForExistence(timeout: 15))
        waitForText(app, codex)
        XCTAssertFalse(app.element("welcome-shell-fallback").exists, "the shell answered")
        XCTAssertTrue(app.element("welcome-agent-grok").exists, "an agent that paddock did not find is listed too")
        XCTAssertTrue(app.buttons["agents-check-again"].exists)
        XCTAssertEqual(loggedPaths, [userPath], "every paddock call has the PATH of the shell")

        // The agent is installed now: Look again finds it.
        let grok = try script("bin/grok", "exit 0")
        app.buttons["agents-check-again"].click()
        waitForText(app, grok)
        XCTAssertEqual(loggedPaths, [userPath])
    }

    // A shell that hangs: after the time limit the usual folders are the
    // PATH, Check this Mac says so in one line, and the agents still show.
    func testAShellThatDoesNotAnswerSaysSo() throws {
        let shell = try script("shell", "sleep 300")
        let fake = Fake("fresh", env: ["PADDOCK_LAUNCHER_SHELL": shell, "PADDOCK_LAUNCHER_SHELL_SECONDS": "1"])
        let app = fake.launch()
        toCheckStep(app)

        XCTAssertTrue(app.element("welcome-shell-fallback").waitForExistence(timeout: 15))
        XCTAssertEqual(app.text("welcome-shell-fallback"), "Your shell did not answer, so paddock for Mac uses the usual folders.")
        XCTAssertTrue(app.element("welcome-agent-claude").waitForExistence(timeout: 10), "the agents show with the usual folders")
        XCTAssertTrue(app.buttons["agents-check-again"].exists)
        XCTAssertTrue(fake.waitForCall("list --json"))
    }

    // Without a test shell, a test run asks no shell: no line about it.
    func testATestRunAsksNoShell() {
        let app = Fake("fresh").launch()
        toCheckStep(app)
        XCTAssertTrue(app.element("welcome-agent-claude").waitForExistence(timeout: 10))
        XCTAssertFalse(app.element("welcome-shell-fallback").exists)
    }
}
