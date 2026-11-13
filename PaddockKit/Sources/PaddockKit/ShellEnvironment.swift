import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// An app that starts from Finder or the Dock gets the PATH of launchd:
// `/usr/bin:/bin:/usr/sbin:/sbin`. The agents live in the folders of the
// user's shell: `/opt/homebrew/bin`, `~/.local/bin`, `~/.grok/bin` and
// others. So the launcher asks the user's login shell for its environment
// once, as editors do, and gives that PATH to every paddock call and to
// the agent panes.

/// Why the shell gave no environment.
public enum ShellFailure: Error, Equatable, Sendable {
    /// The shell did not start: no such file, or not executable.
    case notStarted
    /// No answer within the time limit. The process group was killed.
    case timedOut
    /// More output than the limit. The process group was killed.
    case tooLarge
    /// The shell ended, or closed its output, without the two markers.
    case noAnswer
    /// The answer has no PATH.
    case noPath
    /// The calling task was cancelled. The process group was killed.
    case cancelled
}

/// Reads what the shell printed: noise, the marker, the environment with a
/// NUL after each `NAME=value`, the marker, noise.
public enum ShellOutput {
    /// The environment between the first marker and the next one. Nil when
    /// the output does not have both. Everything outside the markers is
    /// ignored: a greeting of the shell's start files, a prompt, an error.
    ///
    /// The entries are split at the NUL bytes, so a value keeps its
    /// newlines and its `=` signs. An entry that is no `NAME=value`, such
    /// as the rest of a value after a stray NUL, is dropped: it cannot be
    /// a variable, and it must not change the entries next to it.
    public static func parse(_ output: Data, marker: String) -> [String: String]? {
        let mark = Data(marker.utf8)
        guard !mark.isEmpty, let first = output.range(of: mark),
              let second = output.range(of: mark, in: first.upperBound..<output.endIndex) else { return nil }
        var result: [String: String] = [:]
        for entry in output[first.upperBound..<second.lowerBound].split(separator: 0, omittingEmptySubsequences: true) {
            guard let equals = entry.firstIndex(of: UInt8(ascii: "=")) else { continue }
            let name = String(decoding: entry[entry.startIndex..<equals], as: UTF8.self)
            guard isName(name), result[name] == nil else { continue }
            result[name] = String(decoding: entry[entry.index(after: equals)...], as: UTF8.self)
        }
        return result
    }

    /// A variable name: letters, digits and `_`, not a digit first. This
    /// leaves out the exported functions of bash (`BASH_FUNC_x%%`).
    public static func isName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first else { return false }
        func letter(_ c: Unicode.Scalar) -> Bool { (c >= "A" && c <= "Z") || (c >= "a" && c <= "z") || c == "_" }
        return letter(first) && name.unicodeScalars.allSatisfy { letter($0) || ($0 >= "0" && $0 <= "9") }
    }
}

/// One run of the user's shell that prints its environment.
///
/// The shell runs as a login shell and an interactive one (`-l -i`), so it
/// reads the same start files as a Terminal window. It runs in a session
/// of its own: it has no terminal to wait for, and one signal to its
/// process group ends the shell and what its start files started.
public struct ShellProbe: Sendable {
    /// The shell: an absolute path.
    public var shell: String
    /// Printed before and after the environment. A new one for each run,
    /// so no value of the environment can hold it.
    public var marker: String
    /// The time limit. Past it the process group is killed.
    public var seconds: Double
    /// The output limit.
    public var maxBytes: Int
    /// The environment of the shell itself.
    public var environment: [String: String]

    public static let defaultSeconds: Double = 5

    public init(shell: String, marker: String = ShellProbe.newMarker(), seconds: Double = ShellProbe.defaultSeconds,
                maxBytes: Int = 1 << 20, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.shell = shell
        self.marker = marker
        self.seconds = seconds
        self.maxBytes = maxBytes
        self.environment = environment
    }

    public static func newMarker() -> String {
        "__paddock_env_" + UUID().uuidString.replacingOccurrences(of: "-", with: "") + "__"
    }

    /// `/usr/bin/env -0` prints `NAME=value` with a NUL after each. The
    /// full path: an alias or a function named `env` cannot take its
    /// place. The line is the same in zsh, bash, sh and fish.
    public var script: String {
        "printf '%s' '\(marker)'; /usr/bin/env -0; printf '%s' '\(marker)'"
    }

    public var arguments: [String] { ["-l", "-i", "-c", script] }

    /// Runs the shell and returns its environment. A cancel of the calling
    /// task kills the process group.
    public func run() async -> Result<[String: String], ShellFailure> {
        let flag = StopFlag()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: runBlocking(stopped: { flag.isSet }))
                }
            }
        } onCancel: {
            flag.set()
        }
    }

    /// The whole run on the calling thread. It returns when the shell
    /// process is gone: it exited, or it was killed and reaped.
    public func runBlocking(stopped: () -> Bool = { false }) -> Result<[String: String], ShellFailure> {
        guard let child = ShellChild.spawn(shell, arguments: arguments, environment: environment) else {
            return .failure(.notStarted)
        }
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(0, seconds) * 1_000_000_000)
        var output = Data()
        var answer: [String: String]?
        var failure: ShellFailure?
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        reading: while true {
            if stopped() {
                failure = .cancelled
                break
            }
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else {
                failure = .timedOut
                break
            }
            // A short wait, so a cancel is seen soon.
            let wait = Int32(min(50, (deadline - now) / 1_000_000 + 1))
            var descriptor = pollfd(fd: child.output, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, wait)
            if ready < 0 {
                if errno == EINTR { continue }
                failure = .noAnswer
                break
            }
            if ready == 0 { continue }
            let count = chunk.withUnsafeMutableBytes { read(child.output, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                failure = .noAnswer
                break
            }
            if count == 0 {
                // The end of the output without the second marker.
                failure = .noAnswer
                break
            }
            output.append(contentsOf: chunk[0..<count])
            if let parsed = ShellOutput.parse(output, marker: marker) {
                // The answer is whole: what the shell prints later does not count.
                answer = parsed
                break reading
            }
            if output.count > maxBytes {
                failure = .tooLarge
                break
            }
        }
        close(child.output)
        switch failure {
        case .timedOut?, .tooLarge?, .cancelled?:
            child.killGroup()
            child.reap()
        default:
            // The shell answered or closed its output: it gets a moment to
            // exit by itself, then the group is killed.
            child.reap(graceSeconds: 1)
        }
        if let failure { return .failure(failure) }
        guard let answer, let path = answer["PATH"], !path.isEmpty else { return .failure(.noPath) }
        return .success(answer)
    }
}

/// A flag that one thread sets and another reads.
final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

/// The shell process: the leader of a new session, so its process group
/// id is its pid. Until `reap` returns, the pid is not free for another
/// process: a kill of the group cannot reach a stranger.
struct ShellChild {
    let pid: pid_t
    /// The read end of the pipe of the child's stdout.
    let output: Int32

    /// `POSIX_SPAWN_SETSID`: the child starts in a new session. The values
    /// are those of `<spawn.h>` (macOS 10.15 and newer, glibc 2.26 and newer).
    #if canImport(Darwin)
    static let newSession: Int32 = 0x0400
    #else
    static let newSession: Int32 = 0x80
    #endif

    /// Starts `executable` with stdin and stderr on `/dev/null` and stdout
    /// in a pipe. Nil when it did not start.
    static func spawn(_ executable: String, arguments: [String], environment: [String: String]) -> ShellChild? {
        var ends: [Int32] = [-1, -1]
        guard pipe(&ends) == 0 else { return nil }
        let readEnd = ends[0]
        let writeEnd = ends[1]
        // No other child of the launcher inherits the pipe.
        _ = fcntl(readEnd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(writeEnd, F_SETFD, FD_CLOEXEC)

        #if canImport(Darwin)
        var actions: posix_spawn_file_actions_t? = nil
        var attributes: posix_spawnattr_t? = nil
        #else
        var actions = posix_spawn_file_actions_t()
        var attributes = posix_spawnattr_t()
        #endif
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }

        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, writeEnd, 1)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        posix_spawnattr_setflags(&attributes, Int16(newSession))

        var argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) }
        argv.append(nil)
        var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup($0.key + "=" + $0.value) }
        envp.append(nil)
        defer {
            for pointer in argv { free(pointer) }
            for pointer in envp { free(pointer) }
        }

        var pid: pid_t = 0
        let result = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
        close(writeEnd)
        guard result == 0, pid > 0 else {
            close(readEnd)
            return nil
        }
        return ShellChild(pid: pid, output: readEnd)
    }

    /// SIGKILL to the process group: the shell and what it started. Only
    /// before `reap`.
    func killGroup() {
        if kill(-pid, SIGKILL) != 0 { kill(pid, SIGKILL) }
    }

    /// Waits for the exit of the shell and collects it. With a grace time,
    /// a shell that still runs after it is killed with its group.
    func reap(graceSeconds: Double = 0) {
        var status: Int32 = 0
        if graceSeconds > 0 {
            let end = DispatchTime.now().uptimeNanoseconds + UInt64(graceSeconds * 1_000_000_000)
            while DispatchTime.now().uptimeNanoseconds < end {
                let result = waitpid(pid, &status, WNOHANG)
                if result == pid { return }
                if result < 0 && errno != EINTR { return }
                usleep(5_000)
            }
            killGroup()
        }
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
    }
}

// MARK: - The environment of the children

/// Which variables a child of the launcher gets: PATH and a named set,
/// never the whole environment of the shell. A shell environment holds
/// tokens and keys of tools that have nothing to do with paddock.
public enum ChildEnvironment {
    /// What every program needs, and where paddock finds its own files.
    public static let basic: Set<String> = [
        "PATH", "HOME", "USER", "LOGNAME", "SHELL", "TMPDIR",
        "LANG", "LC_ALL", "LC_CTYPE", "LC_MESSAGES",
        "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME",
        // The key agent of the user: for a push that paddock does on the host.
        "SSH_AUTH_SOCK",
    ]

    /// The proxy of the network, in both spellings: without it an agent
    /// behind a proxy does not reach its AI service.
    public static let proxy: Set<String> = [
        "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY",
        "http_proxy", "https_proxy", "all_proxy", "no_proxy",
    ]

    /// The variables that paddock's profiles name for the agents
    /// (`env_pass`): the login of each agent and its model. From the
    /// profiles of paddock 0.2.3. `paddock list --json` does not give
    /// them, so the list is here. paddock decides which of them a sandbox
    /// gets; the launcher only does not hide them from paddock.
    public static let agents: Set<String> = [
        "AMP_API_KEY", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "ANTHROPIC_MODEL",
        "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CODEX_API_KEY", "COMMAND_CODE_API_KEY",
        "COPILOT_GITHUB_TOKEN", "CURSOR_API_KEY", "DASHSCOPE_API_KEY", "DEEPSEEK_API_KEY", "GEMINI_API_KEY",
        "GH_TOKEN", "GITHUB_TOKEN", "GOOGLE_API_KEY", "GOOGLE_CLOUD_PROJECT", "GOOGLE_GENAI_USE_VERTEXAI",
        "GROK_API_KEY", "GROQ_API_KEY", "HYPER_API_KEY", "KILO_API_KEY", "KIMI_MODEL_API_KEY", "KIMI_MODEL_NAME",
        "KIRO_API_KEY", "MCODE_PROVIDER_API_KEY", "META_API_KEY", "MINIMAX_API_KEY", "MOONSHOT_API_KEY",
        "NOUS_API_KEY", "OPENAI_API_KEY", "OPENAI_BASE_URL", "OPENAI_MODEL", "OPENROUTER_API_KEY",
        "QWENCLOUD_API_KEY", "XAI_API_KEY", "ZAI_API_KEY",
    ]

    /// paddock's own variables, such as `PADDOCK_LOG`.
    public static let ownPrefix = "PADDOCK_"

    public static func passes(_ name: String) -> Bool {
        basic.contains(name) || proxy.contains(name) || agents.contains(name) || name.hasPrefix(ownPrefix)
    }

    /// The variables of `environment` that a child gets.
    public static func filter(_ environment: [String: String]) -> [String: String] {
        environment.filter { passes($0.key) }
    }

    /// The needed set from the shell's environment. A variable that the
    /// shell does not have comes from the launcher's own environment.
    public static func merged(shell: [String: String], process: [String: String]) -> [String: String] {
        filter(process).merging(filter(shell)) { _, fromShell in fromShell }
    }
}

/// The PATH when the shell did not answer: the folders where the agents
/// and their tools usually are, then the PATH of the launcher itself.
public enum FallbackPath {
    /// The agents of `paddock list --json` of paddock 0.2.2: each can have
    /// a folder `~/.NAME/bin`. The names that paddock lists at run time
    /// are added to these (`ShellEnvironment.learn`).
    public static let agents = [
        "agy", "amp", "claude", "codex", "commandcode", "copilot", "crush", "cursor-agent", "devin", "dsh",
        "freebuff", "gemini", "grok", "hermes", "kilo", "kimi", "kiro-cli", "mcode", "muse", "omp", "openclaw",
        "opencode", "ori", "pi", "qwen",
    ]

    /// Folders whose name is not the name of the agent.
    static let extra = [".kimi-code/bin"]

    /// A name that is safe as one folder name: no `/`, no leading dot.
    public static func isAgentName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, first != ".", first != "-" else { return false }
        return name.unicodeScalars.allSatisfy { c in
            (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || (c >= "0" && c <= "9") || c == "-" || c == "_" || c == "."
        }
    }

    /// The usual install folders, in order.
    public static func folders(home: String, agents: [String]) -> [String] {
        var list = ["/opt/homebrew/bin", "/usr/local/bin"]
        guard !home.isEmpty else { return list }
        let base = home.hasSuffix("/") ? String(home.dropLast()) : home
        list += [".local/bin", ".bun/bin", ".npm-global/bin", ".cargo/bin"].map { base + "/" + $0 }
        list += agents.filter(isAgentName).map { base + "/." + $0 + "/bin" }
        list += extra.map { base + "/" + $0 }
        return list
    }

    /// The folders, then the entries of `inherited` that are not among
    /// them. No folder twice.
    public static func path(home: String, agents: [String], inherited: String?) -> String {
        var seen = Set<String>()
        let own = (inherited ?? "").split(separator: ":").map(String.init)
        let system = own.isEmpty ? ["/usr/bin", "/bin", "/usr/sbin", "/sbin"] : own
        return (folders(home: home, agents: agents) + system).filter { seen.insert($0).inserted }.joined(separator: ":")
    }
}

/// The environment that the children of the launcher get, and where it
/// comes from.
public struct LauncherEnvironment: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        /// The shell at this path answered.
        case shell(String)
        /// The shell did not answer: the PATH is `FallbackPath`.
        case fallback(shell: String, reason: ShellFailure)
        /// No shell was asked: the environment of the launcher itself.
        case inherited
    }

    public var source: Source
    /// `PATH` and the needed set (`ChildEnvironment`).
    public var variables: [String: String]

    public init(source: Source, variables: [String: String]) {
        self.source = source
        self.variables = variables
    }

    public var path: String { variables["PATH"] ?? "" }

    /// True when the shell did not answer: Check this Mac says so.
    public var isFallback: Bool {
        if case .fallback = source { return true }
        return false
    }

    /// True when the PATH is the one of the user's shell.
    public var isFromShell: Bool {
        if case .shell = source { return true }
        return false
    }

    /// The environment after the shell answered.
    public static func resolved(shell path: String, answer: [String: String], process: [String: String]) -> LauncherEnvironment {
        LauncherEnvironment(source: .shell(path), variables: ChildEnvironment.merged(shell: answer, process: process))
    }

    /// The environment after the shell failed.
    public static func fallback(shell path: String, reason: ShellFailure, process: [String: String], home: String,
                                agents: [String]) -> LauncherEnvironment {
        var variables = ChildEnvironment.filter(process)
        variables["PATH"] = FallbackPath.path(home: home, agents: agents, inherited: process["PATH"])
        if variables["HOME"] == nil, !home.isEmpty { variables["HOME"] = home }
        return LauncherEnvironment(source: .fallback(shell: path, reason: reason), variables: variables)
    }

    /// The launcher's own environment, with no shell asked.
    public static func inherited(process: [String: String]) -> LauncherEnvironment {
        LauncherEnvironment(source: .inherited, variables: ChildEnvironment.filter(process))
    }
}

/// The environment of the user's shell, resolved once and kept for the
/// session. `current` is what every paddock call and every agent pane
/// gets. `refresh` asks the shell again: Check Again, Look again, and a
/// change of the shell in Settings.
public final class ShellEnvironment: @unchecked Sendable {
    /// Runs the shell at the path. The tests give a fake.
    public typealias Ask = @Sendable (String) async -> Result<[String: String], ShellFailure>

    private let lock = NSLock()
    private var value: LauncherEnvironment
    private var resolved = false
    private var generation = 0
    private var agents = FallbackPath.agents
    private let process: @Sendable () -> [String: String]
    private let home: String
    private let ask: Ask?

    /// `ask` nil: no shell runs, and `current` stays the launcher's own
    /// environment. The UI tests run so.
    public init(process: @escaping @Sendable () -> [String: String] = { ProcessInfo.processInfo.environment },
                home: String, ask: Ask?) {
        self.process = process
        self.home = home
        self.ask = ask
        value = .inherited(process: process())
    }

    /// The real shell, with the time limit of `ShellProbe`.
    public static func live(home: String) -> ShellEnvironment {
        ShellEnvironment(home: home, ask: { shell in await ShellProbe(shell: shell).run() })
    }

    /// The shell to ask: the choice of Settings, else `$SHELL`, else
    /// `/bin/zsh`. Only an absolute path counts.
    public static func shellPath(chosen: String?, environment: [String: String]) -> String {
        for candidate in [chosen, environment["SHELL"]] {
            if let path = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), path.hasPrefix("/") { return path }
        }
        return "/bin/zsh"
    }

    /// What the children get now.
    public var current: LauncherEnvironment {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    /// The cached environment; the first call asks the shell.
    @discardableResult
    public func resolve(chosen: String? = nil) async -> LauncherEnvironment {
        lock.lock()
        let done = resolved
        let cached = value
        lock.unlock()
        return done ? cached : await refresh(chosen: chosen)
    }

    /// Asks the shell again and replaces the cached environment. When two
    /// calls overlap, the answer of the later one stays.
    @discardableResult
    public func refresh(chosen: String? = nil) async -> LauncherEnvironment {
        let own = process()
        guard let ask else {
            return store(.inherited(process: own), ifCurrent: nil)
        }
        lock.lock()
        generation += 1
        let mine = generation
        let names = agents
        lock.unlock()
        let shell = ShellEnvironment.shellPath(chosen: chosen, environment: own)
        let next: LauncherEnvironment
        switch await ask(shell) {
        case .success(let answer):
            next = .resolved(shell: shell, answer: answer, process: own)
        case .failure(let reason):
            next = .fallback(shell: shell, reason: reason, process: own, home: home, agents: names)
        }
        return store(next, ifCurrent: mine)
    }

    private func store(_ next: LauncherEnvironment, ifCurrent mine: Int?) -> LauncherEnvironment {
        lock.lock()
        defer { lock.unlock() }
        if let mine, mine != generation { return value }
        value = next
        resolved = true
        return value
    }

    /// The agents that paddock lists. With the fallback PATH, each new
    /// name adds its folder `~/.NAME/bin`. True when the PATH changed: the
    /// caller reads the list once more.
    @discardableResult
    public func learn(agents listed: [String]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let new = listed.filter { FallbackPath.isAgentName($0) && !agents.contains($0) }
        guard !new.isEmpty else { return false }
        agents += new
        guard case .fallback = value.source else { return false }
        let path = FallbackPath.path(home: home, agents: agents, inherited: process()["PATH"])
        guard path != value.variables["PATH"] else { return false }
        value.variables["PATH"] = path
        return true
    }
}
