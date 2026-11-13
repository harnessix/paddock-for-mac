import Foundation

/// Finds the paddock binary in a fixed order.
///
/// 1. `PADDOCK_BIN`, in debug builds only.
/// 2. `/opt/homebrew/bin/paddock`
/// 3. `/usr/local/bin/paddock`
/// 4. `~/.local/bin/paddock`
/// 5. `$(brew --prefix)/bin/paddock`, with brew from `/opt/homebrew/bin/brew`
///    or `/usr/local/bin/brew`.
public struct BinaryLocator {
    public var environment: [String: String]
    public var home: String
    public var isDebugBuild: Bool
    /// True when an executable file exists at the path.
    public var isExecutable: (String) -> Bool
    /// Runs `BREW --prefix` and returns the prefix, or nil.
    public var brewPrefix: (String) -> String?
    /// Debug builds only: a folder put in front of every fixed path, so a
    /// test on a Mac that has paddock installed can see "missing".
    public var searchRoot: String

    public init(environment: [String: String], home: String, isDebugBuild: Bool,
                isExecutable: @escaping (String) -> Bool, brewPrefix: @escaping (String) -> String?) {
        self.environment = environment
        self.home = home
        self.isDebugBuild = isDebugBuild
        self.isExecutable = isExecutable
        self.brewPrefix = brewPrefix
        self.searchRoot = isDebugBuild ? (environment["PADDOCK_LAUNCHER_SEARCH_ROOT"] ?? "") : ""
    }

    /// The fixed candidates in order, without the brew prefix one.
    public var fixedCandidates: [String] {
        var list: [String] = []
        if isDebugBuild, let bin = environment["PADDOCK_BIN"], !bin.isEmpty { list.append(bin) }
        list.append(searchRoot + "/opt/homebrew/bin/paddock")
        list.append(searchRoot + "/usr/local/bin/paddock")
        list.append(searchRoot + home + "/.local/bin/paddock")
        return list
    }

    public func locate() -> String? {
        for path in fixedCandidates where isExecutable(path) { return path }
        for brew in [searchRoot + "/opt/homebrew/bin/brew", searchRoot + "/usr/local/bin/brew"] where isExecutable(brew) {
            if let prefix = brewPrefix(brew) {
                let path = prefix.trimmingCharacters(in: .whitespacesAndNewlines) + "/bin/paddock"
                if isExecutable(path) { return path }
            }
        }
        return nil
    }
}

/// Compares `paddock --version` with the launcher's compiled-in range.
/// The comparison is major, minor and patch: 0.2.1 is older than 0.2.2.
public struct VersionGate: Equatable, Sendable {
    /// The oldest paddock this launcher works with.
    public var minimum: (major: Int, minor: Int, patch: Int)
    /// The newest major this launcher knows.
    public var supportedMajor: Int

    /// paddock 0.2.2 is the first with the JSON and the events this launcher
    /// reads. Any 0.x from there on works; 1.0 needs a newer launcher.
    public static let current = VersionGate(minimum: (0, 2, 2), supportedMajor: 0)

    public init(minimum: (major: Int, minor: Int, patch: Int), supportedMajor: Int) {
        self.minimum = minimum
        self.supportedMajor = supportedMajor
    }

    /// A minimum without a patch number means patch 0.
    public init(minimum: (major: Int, minor: Int), supportedMajor: Int) {
        self.init(minimum: (minimum.major, minimum.minor, 0), supportedMajor: supportedMajor)
    }

    public static func == (a: VersionGate, b: VersionGate) -> Bool {
        a.minimum == b.minimum && a.supportedMajor == b.supportedMajor
    }

    /// `0.2.2`, or `0.3` when the patch is 0.
    public var minimumText: String {
        minimum.patch == 0 ? "\(minimum.major).\(minimum.minor)" : "\(minimum.major).\(minimum.minor).\(minimum.patch)"
    }

    public enum Verdict: Equatable, Sendable {
        case ok(version: String)
        case tooOld(have: String, need: String)
        case tooNew(have: String)
        case unreadable(output: String)
        /// The version is in range, but the launcher protocol check failed.
        /// `version` is empty when `--version` itself did not answer.
        case incompatible(version: String, reason: LauncherProtocol.Failure)
    }

    /// Reads `paddock 0.4.2` (or `0.4.2`) and gives the verdict.
    public func check(versionOutput: String) -> Verdict {
        guard let version = VersionGate.parse(versionOutput) else {
            return .unreadable(output: versionOutput)
        }
        let text = "\(version.major).\(version.minor).\(version.patch)"
        if version.major > supportedMajor { return .tooNew(have: text) }
        if (version.major, version.minor, version.patch) < (minimum.major, minimum.minor, minimum.patch) {
            return .tooOld(have: text, need: minimumText)
        }
        return .ok(version: text)
    }

    public static func parse(_ output: String) -> (major: Int, minor: Int, patch: Int)? {
        let words = output.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
        for word in words {
            let trimmed = word.hasPrefix("v") ? word.dropFirst() : Substring(word)
            let core = trimmed.split(separator: "-").first ?? trimmed
            let parts = core.split(separator: ".").map { Int($0) }
            if parts.count >= 2, let major = parts[0], let minor = parts[1] {
                let patch = parts.count > 2 ? (parts[2] ?? 0) : 0
                return (major, minor, patch)
            }
        }
        return nil
    }

    public func error(for verdict: Verdict) -> LauncherError? {
        switch verdict {
        case .ok: return nil
        case .tooOld(let have, let need): return .tooOld(have: have, need: need)
        case .tooNew(let have): return .tooNew(have: have)
        case .unreadable: return .notInstalled
        case .incompatible(let version, let reason): return .incompatible(version: version, reason: reason)
        }
    }
}

/// One row of the onboarding checklist.
public struct PrereqRow: Equatable, Sendable, Identifiable {
    /// The checks of `paddock doctor` that the launcher knows, the
    /// binary check (`paddock`), a doctor that gave no report (`doctor`),
    /// and `other` for a check of a newer paddock.
    public enum Kind: String, Equatable, Sendable {
        case chip, macos, paddock, doctor, space, memory, entitlement, slots, other
    }

    public enum Status: Equatable, Sendable {
        case checking, pass, warning, fail
    }

    public enum Action: Equatable, Sendable {
        case quit
        case updateMacOS
        case copyInstall
        case copyUpgrade
        case manageStorage
        case checkAgain
    }

    public var kind: Kind
    public var status: Status
    public var title: UIText
    public var result: UIText
    public var actions: [Action]
    /// A command shown in a text field with Copy.
    public var command: String?
    /// paddock's check id for a check of kind `other`.
    public var checkID: String?

    public init(kind: Kind, status: Status, title: UIText, result: UIText, actions: [Action],
                command: String? = nil, checkID: String? = nil) {
        self.kind = kind
        self.status = status
        self.title = title
        self.result = result
        self.actions = actions
        self.command = command
        self.checkID = checkID
    }

    /// The kind, or paddock's id for a check this launcher does not know.
    /// The view's accessibility identifier is `prereq-` + id.
    public var id: String { kind == .other ? "other-" + (checkID ?? "") : kind.rawValue }

    public var symbol: String {
        switch status {
        case .checking: return "clock"
        case .pass: return "checkmark.circle"
        case .warning: return "exclamationmark.circle"
        case .fail: return "xmark.circle"
        }
    }

    public var tint: SymbolTint {
        switch status {
        case .checking: return .secondary
        case .pass: return .green
        case .warning: return .orange
        case .fail: return .red
        }
    }

    public var accessibilityLabel: UIText {
        switch status {
        case .checking: return UIText("Checking")
        case .pass: return UIText("Passed")
        case .warning: return UIText("Warning")
        case .fail: return UIText("Failed")
        }
    }
}

/// Builds the checklist of onboarding step 2 from `paddock doctor --json`
/// and the binary check.
///
/// paddock's report is the truth: each entry of `checks` is one row, with
/// paddock's level and paddock's line. A `fail` line says what to do, and
/// the row has Check Again. A report without `checks` (the launcher's own
/// look at this Mac when paddock is missing) gives the four rows from the
/// numbers. A doctor that did not answer, or answered with no report,
/// is one failed row: never a row that still checks.
public enum Prerequisites {
    public static let memoryWarnBelow: Int64 = 16 * 1024 * 1024 * 1024

    /// `binary` is nil while it is unknown, the verdict once known.
    /// `doctor` nil means the doctor still runs.
    public static func rows(doctor: DoctorJSON?, binary: VersionGate.Verdict?, binaryMissing: Bool) -> [PrereqRow] {
        rows(phase: doctor.map(DoctorPhase.report) ?? .checking, binary: binary, binaryMissing: binaryMissing)
    }

    public static func rows(phase: DoctorPhase, binary: VersionGate.Verdict?, binaryMissing: Bool) -> [PrereqRow] {
        var rows: [PrereqRow] = [paddockRow(binary: binary, missing: binaryMissing)]
        switch phase {
        case .checking:
            for kind in [PrereqRow.Kind.chip, .macos, .space, .memory] {
                rows.append(PrereqRow(kind: kind, status: .checking, title: title(kind), result: UIText("Checking…"), actions: []))
            }
        case .noAnswer:
            rows.append(PrereqRow(kind: .doctor, status: .fail, title: title(.doctor),
                                  result: LibraryCopy.noAnswer,
                                  actions: [.checkAgain]))
        case .failed(let line):
            rows.append(PrereqRow(kind: .doctor, status: .fail, title: title(.doctor),
                                  result: UIText("paddock doctor gave no report: %@", line), actions: [.checkAgain]))
        case .report(let doctor):
            let checks = doctor.checks.isEmpty ? derivedRows(doctor) : doctor.checks.map(row(of:))
            if checks.isEmpty {
                rows.append(PrereqRow(kind: .doctor, status: .fail, title: title(.doctor),
                                      result: UIText("paddock doctor gave no checks."), actions: [.checkAgain]))
            }
            rows += checks
        }
        return order(rows)
    }

    /// paddock's check id to the row kind.
    public static func kind(ofCheck id: String) -> PrereqRow.Kind {
        switch id {
        case "apple_silicon", "chip": return .chip
        case "macos": return .macos
        case "free_space", "disk", "space": return .space
        case "memory": return .memory
        case "entitlement": return .entitlement
        case "slots": return .slots
        default: return .other
        }
    }

    /// paddock's level word. A word this launcher does not know is a
    /// warning: it does not block, and it does not look like a pass.
    public static func status(ofLevel level: String) -> PrereqRow.Status {
        switch level.lowercased() {
        case "ok", "pass", "info": return .pass
        case "fail", "error", "failed": return .fail
        default: return .warning
        }
    }

    /// One row from one check of paddock's report, with paddock's line.
    static func row(of check: DoctorCheckJSON) -> PrereqRow {
        let rowKind = Prerequisites.kind(ofCheck: check.id)
        let rowStatus = Prerequisites.status(ofLevel: check.level)
        let rowTitle = rowKind == .other ? UIText.cli(humanize(check.id), else: UIText("Another check")) : title(rowKind)
        return PrereqRow(kind: rowKind, status: rowStatus, title: rowTitle, result: UIText.cli(check.text, else: CLIWords.seeDetails),
                         actions: rowStatus == .fail ? failActions(rowKind) : [],
                         checkID: rowKind == .other ? check.id : nil)
    }

    /// The buttons of a failed row. Every failed row can be checked again,
    /// except a Mac without Apple silicon: no check changes that.
    static func failActions(_ kind: PrereqRow.Kind) -> [PrereqRow.Action] {
        switch kind {
        case .chip: return [.quit]
        case .macos: return [.updateMacOS, .checkAgain]
        case .space: return [.manageStorage, .checkAgain]
        default: return [.checkAgain]
        }
    }

    /// The four rows from the numbers of a report without `checks`.
    static func derivedRows(_ d: DoctorJSON) -> [PrereqRow] {
        var rows: [PrereqRow] = []
        if let chip = d.chip {
            if chip.appleSilicon {
                rows.append(PrereqRow(kind: .chip, status: .pass, title: title(.chip),
                                      result: UIText("This Mac has an M-series chip"), actions: []))
            } else {
                rows.append(PrereqRow(kind: .chip, status: .fail, title: title(.chip),
                                      result: UIText("paddock app mode needs a Mac with Apple silicon."),
                                      actions: failActions(.chip)))
            }
        }
        if let macos = d.macos {
            if macos.ok {
                rows.append(PrereqRow(kind: .macos, status: .pass, title: title(.macos),
                                      result: UIText("macOS %@", macos.version), actions: []))
            } else {
                rows.append(PrereqRow(kind: .macos, status: .fail, title: title(.macos),
                                      result: UIText("This Mac has macOS %@.", macos.version), actions: failActions(.macos)))
            }
        }
        if let disk = d.disk {
            if disk.free >= disk.need {
                rows.append(PrereqRow(kind: .space, status: .pass, title: title(.space),
                                      result: UIText("%@ free, %@ needed", Format.gb(disk.free), Format.gb(disk.need)),
                                      actions: []))
            } else {
                rows.append(PrereqRow(kind: .space, status: .fail, title: title(.space),
                                      result: UIText("Needs %@, %@ free. Free up space, then click Check again.",
                                                     Format.gb(disk.need), Format.gb(disk.free)),
                                      actions: failActions(.space)))
            }
        }
        if let memory = d.memory {
            if memory.bytes >= memoryWarnBelow {
                rows.append(PrereqRow(kind: .memory, status: .pass, title: title(.memory),
                                      result: UIText("%@; each app gets up to 8 GB", Format.memoryGB(memory.bytes)),
                                      actions: []))
            } else {
                rows.append(PrereqRow(kind: .memory, status: .warning, title: title(.memory),
                                      result: UIText("%@; apps get 4 GB each, which is the minimum.",
                                                     Format.memoryGB(memory.bytes)),
                                      actions: []))
            }
        }
        return rows
    }

    /// `some_new_check` -> `Some new check`.
    static func humanize(_ id: String) -> String {
        let words = id.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    static func paddockRow(binary: VersionGate.Verdict?, missing: Bool) -> PrereqRow {
        if missing {
            return PrereqRow(kind: .paddock, status: .fail, title: title(.paddock), result: UIText("Not installed"),
                             actions: [.copyInstall, .checkAgain], command: ShellCommands.brewInstall)
        }
        switch binary {
        case .none:
            return PrereqRow(kind: .paddock, status: .checking, title: title(.paddock), result: UIText("Checking…"), actions: [])
        case .ok(let version)?:
            return PrereqRow(kind: .paddock, status: .pass, title: title(.paddock), result: UIText("paddock %@ found", version), actions: [])
        case .tooOld(let have, let need)?:
            return PrereqRow(kind: .paddock, status: .fail, title: title(.paddock),
                             result: UIText("Update paddock: this Mac has %@, paddock for Mac needs %@ or newer.", have, need),
                             actions: [.copyUpgrade, .checkAgain], command: ShellCommands.brewUpgrade)
        case .tooNew(let have)?:
            return PrereqRow(kind: .paddock, status: .fail, title: title(.paddock),
                             result: UIText("Update paddock for Mac: paddock %@ is newer than it knows.", have),
                             actions: [.copyUpgrade, .checkAgain], command: ShellCommands.brewUpgradeLauncher)
        case .unreadable?:
            return PrereqRow(kind: .paddock, status: .fail, title: title(.paddock), result: UIText("Not installed"),
                             actions: [.copyInstall, .checkAgain], command: ShellCommands.brewInstall)
        case .incompatible(let version, let reason)?:
            let error = LauncherError.incompatible(version: version, reason: reason)
            let result = error.body ?? UIText("Not installed")
            guard let command = error.command else {
                return PrereqRow(kind: .paddock, status: .fail, title: title(.paddock), result: result,
                                 actions: [.checkAgain])
            }
            return PrereqRow(kind: .paddock, status: .fail, title: title(.paddock), result: result,
                             actions: [.copyUpgrade, .checkAgain], command: command)
        }
    }

    static func title(_ kind: PrereqRow.Kind) -> UIText {
        switch kind {
        case .chip: return UIText("Apple silicon")
        case .macos: return UIText("macOS 14 or newer")
        case .paddock: return UIText("paddock command")
        case .doctor: return UIText("paddock doctor")
        case .space: return UIText("Free space")
        case .memory: return UIText("Memory")
        case .entitlement: return UIText("Virtualization")
        case .slots: return UIText("Virtual machines")
        case .other: return UIText("Other check")
        }
    }

    /// The known kinds in a fixed order; checks of a newer paddock after
    /// them, in paddock's order.
    static func order(_ rows: [PrereqRow]) -> [PrereqRow] {
        let order: [PrereqRow.Kind] = [.chip, .macos, .paddock, .doctor, .space, .memory, .entitlement, .slots, .other]
        return rows.enumerated().sorted { a, b in
            let x = order.firstIndex(of: a.element.kind)!
            let y = order.firstIndex(of: b.element.kind)!
            return x == y ? a.offset < b.offset : x < y
        }.map(\.element)
    }

    /// Continue is enabled when no row fails and none is still checking.
    /// Warnings are allowed.
    public static func canContinue(_ rows: [PrereqRow]) -> Bool {
        rows.allSatisfy { $0.status == .pass || $0.status == .warning }
    }

    /// An Intel Mac is a dead end: the only way out is Quit.
    public static func isDeadEnd(_ rows: [PrereqRow]) -> Bool {
        rows.contains { $0.kind == .chip && $0.status == .fail }
    }
}
