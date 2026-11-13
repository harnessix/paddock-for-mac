import Foundation

// The JSON shapes of `paddock ... --json`. Keys are snake_case in JSON and
// camelCase here (`PaddockJSON.decoder` converts them). Every top-level
// object carries `v`, the schema version. Unknown fields are ignored, so a
// newer paddock that adds fields still decodes.

public enum PaddockJSON {
    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// The schema version the launcher reads. A higher `v` still decodes
    /// as long as the fields below stay.
    public static let schemaVersion = 1
}

// MARK: - Base image (golden)

public struct GoldenJSON: Codable, Equatable, Sendable {
    /// `none`, `building`, `failed`, `ready`, `needs_update`.
    public var state: String
    public var version: String?
    public var built: Date?
    public var sizeBytes: Int64?
    public var dir: String?
    public var hostVersion: String?
    public var appsUsing: Int?
    public var logPath: String?
    public var setup: SetupJSON?
}

public struct SetupJSON: Codable, Equatable, Sendable {
    /// `download`, `install`, `guided`, `seal`, `done`.
    public var step: String
    public var bytes: Int64?
    public var total: Int64?
    /// Bytes per second, as paddock measures it.
    public var rate: Double?
    public var paused: Bool?
    public var time: Date?
    public var failed: SetupFailureJSON?

    public init(step: String, bytes: Int64? = nil, total: Int64? = nil, rate: Double? = nil,
                paused: Bool? = nil, time: Date? = nil, failed: SetupFailureJSON? = nil) {
        self.step = step
        self.bytes = bytes
        self.total = total
        self.rate = rate
        self.paused = paused
        self.time = time
        self.failed = failed
    }
}

public struct SetupFailureJSON: Codable, Equatable, Sendable {
    /// `no_space`, `download_interrupted`, `unsupported_image`,
    /// `wrong_password` or another code.
    public var code: String
    /// paddock's reason line, shown verbatim.
    public var reason: String
}

public struct DiskJSON: Codable, Equatable, Sendable {
    public var freeBytes: Int64
    public var totalBytes: Int64?
    public var usedByPaddockBytes: Int64?
    public var ipswBytes: Int64?
    public var trashBytes: Int64?
    public var trashDir: String?
}

public struct MacvmStatusJSON: Codable, Equatable, Sendable {
    public var v: Int
    public var golden: GoldenJSON
    public var disk: DiskJSON?
    public var logDir: String?
}

// MARK: - Apps

public struct AppSizesJSON: Codable, Equatable, Sendable {
    public var appCopy: Int64
    public var data: Int64
    public var savedState: Int64

    public init(appCopy: Int64, data: Int64, savedState: Int64) {
        self.appCopy = appCopy
        self.data = data
        self.savedState = savedState
    }

    public var total: Int64 { appCopy + data + savedState }
}

public struct AppJSON: Codable, Equatable, Sendable, Identifiable {
    public var name: String
    public var bundlePath: String?
    /// `stopped`, `saved`, `starting`, `running`, `stopping`, `error`, `blocked`.
    public var state: String
    /// For `starting`: `cloning`, `booting`, `copying_app`, `opening`, `resuming`.
    public var phase: String?
    public var since: Date?
    public var windows: Int?
    /// The short reason of `error` or `blocked`, paddock's words.
    public var reason: String?
    /// For `blocked`: `app_store`, `bundle_missing`, `low_disk`, `no_golden`.
    public var blockCode: String?
    /// The `Next start` line, shown verbatim.
    public var nextStart: String?
    /// paddock's own `next_start` word: `warm`, `cold`, `cold: REASON` or
    /// `refused: REASON`. `NextStartCopy.line` makes the text from it.
    public var nextStartRaw: String?
    public var memoryBytes: Int64?
    public var hostMemoryBytes: Int64?
    public var sizes: AppSizesJSON?
    /// `ask`, `allowlist`, `none`.
    public var network: String?
    public var openQuestions: Int?
    public var ruleCount: Int?
    /// The `Base image` line, verbatim: `macOS 15.1 (sealed)`.
    public var golden: String?
    /// True when the host app changed since the last copy.
    public var appChanged: Bool?
    /// False while the guest agent is away.
    public var agentConnected: Bool?
    /// The crash row of paddock's failure table after an unexpected stop.
    public var crash: String?
    /// paddock's line after a failed app copy. The app runs the old copy.
    public var copyFailed: String?
    /// The home folder of the instance: `default` or `instance-N`.
    public var home: String?
    /// The app's own name from its bundle: `Sample Notes` for `sample-notes`.
    public var displayName: String?
    /// The bundle version of the host app.
    public var version: String?
    /// The disk use of the profile instance.
    public var bytes: Int64?
    /// True when `~/Applications/<Name> (paddock).app` exists.
    public var launcher: Bool?
    /// Why paddock suspended the session, for `suspended`.
    public var suspendReason: String?
    /// Free bytes on the disk of the profile, from paddock's `app list`
    /// (`status.host.disk_free`). paddock 0.2.2 `macvm status` has no disk.
    public var hostDiskFree: Int64?

    public var id: String { InstanceRef(app: name, home: home).key }
}

public struct AppListJSON: Codable, Equatable, Sendable {
    public var v: Int
    public var apps: [AppJSON]
}

public struct ShareJSON: Codable, Equatable, Sendable, Identifiable {
    public var path: String
    /// `ro` or `rw`.
    public var mode: String
    public var lastUsed: Date?
    public var openHandles: Int?
    public var guestPath: String?
    /// `live`, `next_start` or `reopen`.
    public var applies: String?
    /// `grant` (kept in the profile) or `run` (shared by this session only).
    public var from: String?

    public var id: String { path }

    public init(path: String, mode: String, lastUsed: Date? = nil, openHandles: Int? = nil,
                guestPath: String? = nil, applies: String? = nil, from: String? = nil) {
        self.path = path
        self.mode = mode
        self.lastUsed = lastUsed
        self.openHandles = openHandles
        self.guestPath = guestPath
        self.applies = applies
        self.from = from
    }
}

public struct RuleJSON: Codable, Equatable, Sendable, Identifiable {
    public var host: String
    /// `allow` or `deny`.
    public var answer: String
    /// `always` or `session`.
    public var scope: String
    public var added: Date?
    public var lastUsed: Date?
    public var count: Int?
    /// True for a rule from the app profile's seed hosts.
    public var seeded: Bool?

    public var id: String { host + "|" + answer + "|" + scope }

    public init(host: String, answer: String, scope: String, added: Date? = nil,
                lastUsed: Date? = nil, count: Int? = nil, seeded: Bool? = nil) {
        self.host = host
        self.answer = answer
        self.scope = scope
        self.added = added
        self.lastUsed = lastUsed
        self.count = count
        self.seeded = seeded
    }
}

public struct ClipboardJSON: Codable, Equatable, Sendable {
    public var toApp: Bool
    public var fromApp: Bool

    public init(toApp: Bool, fromApp: Bool) {
        self.toApp = toApp
        self.fromApp = fromApp
    }
}

public struct DeviceJSON: Codable, Equatable, Sendable, Identifiable {
    public var name: String
    public var enabled: Bool
    /// Always `next_start`: devices attach when the app starts.
    public var applies: String?
    public var id: String { name }
}

public struct ChangeJSON: Codable, Equatable, Sendable, Identifiable {
    public var time: Date
    /// paddock's text: `Allow always api.example.com`.
    public var text: String
    /// `you`, `question_panel`, `profile`.
    public var source: String

    public var id: String { "\(time.timeIntervalSince1970)|\(text)|\(source)" }

    public init(time: Date, text: String, source: String) {
        self.time = time
        self.text = text
        self.source = source
    }
}

/// `paddock app status NAME --json`: the list fields plus the grants.
public struct AppStatusJSON: Codable, Equatable, Sendable {
    public var v: Int
    public var app: AppJSON
    public var downloads: String?
    public var shares: [ShareJSON]?
    public var rules: [RuleJSON]?
    public var networkText: String?
    public var openConnections: Int?
    public var clipboard: ClipboardJSON?
    public var devices: [DeviceJSON]?
    public var changes: [ChangeJSON]?
    public var logPath: String?
}

// MARK: - Questions

public struct QuestionJSON: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var app: String
    public var host: String
    public var port: Int
    /// `Sample Notes.app → helper (Renderer)`.
    public var process: String?
    public var opened: Date?

    public init(id: String, app: String, host: String, port: Int, process: String? = nil, opened: Date? = nil) {
        self.id = id
        self.app = app
        self.host = host
        self.port = port
        self.process = process
        self.opened = opened
    }
}

public struct PausedJSON: Codable, Equatable, Sendable {
    public var app: String
    public var count: Int
    /// The current paddock notice card, absent in older snapshots.
    public var id: String? = nil
}

public struct ApprovalsJSON: Codable, Equatable, Sendable {
    public var v: Int
    public var questions: [QuestionJSON]
    public var paused: PausedJSON?
    public var complete: Bool
    public var diagnostics: [String]
    /// The requests of terminal agents: every pending card that is not a
    /// connect question (a host command, a git push, a device…).
    public var requests: [AgentRequestJSON] = []

    private enum CodingKeys: String, CodingKey { case v, questions, paused, pending, complete, diagnostics, requests }

    /// One pending card, or nil when it does not decode: a card of an
    /// unknown shape never hides the others.
    private struct Lenient<T: Decodable>: Decodable {
        var value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }

    private struct Pending: Decodable {
        var id: String
        var capability: String
        var connect: Connection?
    }

    private struct Connection: Decodable {
        var profile: String?
        var host: String?
        var port: Int?
        var path: String?
        var askedAt: Double?
        var notice: Bool?
        var more: Int?
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        v = try values.decode(Int.self, forKey: .v)
        complete = try values.decodeIfPresent(Bool.self, forKey: .complete) ?? true
        diagnostics = try values.decodeIfPresent([String].self, forKey: .diagnostics) ?? []
        if let legacy = try values.decodeIfPresent([QuestionJSON].self, forKey: .questions) {
            questions = legacy
            paused = try values.decodeIfPresent(PausedJSON.self, forKey: .paused)
            requests = (try? values.decodeIfPresent([AgentRequestJSON].self, forKey: .requests)) ?? []
            return
        }
        let pending = try values.decode([Pending].self, forKey: .pending)
        let cards = try values.decode([Lenient<AgentRequestJSON>].self, forKey: .pending)
        requests = cards.compactMap(\.value).filter { $0.capability != "connect" }
        questions = []
        paused = nil
        for item in pending where item.capability == "connect" {
            guard let c = item.connect else { continue }
            let app = c.profile ?? ""
            if c.notice == true {
                // The launcher currently presents one pause banner.
                if paused == nil { paused = PausedJSON(app: app, count: c.more ?? 0, id: item.id) }
            } else {
                questions.append(QuestionJSON(id: item.id, app: app, host: c.host ?? "", port: c.port ?? 0,
                                              process: c.path,
                                              opened: c.askedAt.map { Date(timeIntervalSince1970: $0) }))
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(v, forKey: .v)
        try values.encode(questions, forKey: .questions)
        try values.encodeIfPresent(paused, forKey: .paused)
        try values.encode(complete, forKey: .complete)
        try values.encode(diagnostics, forKey: .diagnostics)
        if !requests.isEmpty { try values.encode(requests, forKey: .requests) }
    }
}

// MARK: - Doctor and add precheck

/// `paddock doctor --json`, as paddock 0.2.2 prints it:
/// `{"v":1,"ok":true,"checks":[{"id","level","text"}],"chip":{...},...}`.
/// `checks` is the report the launcher shows; the objects next to it are
/// the numbers behind it. paddock exits 1 when a check fails and still
/// prints the whole report. Every part is read on its own, so one part of
/// a newer shape cannot hide the rest.
public struct DoctorJSON: Codable, Equatable, Sendable {
    public var v: Int
    /// False when a check failed.
    public var ok: Bool?
    public var checks: [DoctorCheckJSON]
    public var chip: DoctorChipJSON?
    public var disk: DoctorDiskJSON?
    public var macos: DoctorMacOSJSON?
    public var memory: DoctorMemoryJSON?
    public var entitlement: DoctorEntitlementJSON?
    public var golden: DoctorGoldenJSON?
    public var slots: DoctorSlotsJSON?
    public var paddock: DoctorPaddockJSON?

    public init(v: Int = 1, ok: Bool? = nil, checks: [DoctorCheckJSON] = [], chip: DoctorChipJSON? = nil,
                disk: DoctorDiskJSON? = nil, macos: DoctorMacOSJSON? = nil, memory: DoctorMemoryJSON? = nil,
                entitlement: DoctorEntitlementJSON? = nil, golden: DoctorGoldenJSON? = nil,
                slots: DoctorSlotsJSON? = nil, paddock: DoctorPaddockJSON? = nil) {
        self.v = v
        self.ok = ok
        self.checks = checks
        self.chip = chip
        self.disk = disk
        self.macos = macos
        self.memory = memory
        self.entitlement = entitlement
        self.golden = golden
        self.slots = slots
        self.paddock = paddock
    }

    private enum CodingKeys: String, CodingKey {
        case v, ok, checks, chip, disk, macos, memory, entitlement, golden, slots, paddock
    }

    /// The report must have `v`, and `checks` or one of the objects: any
    /// other JSON object is not a doctor report.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        v = try values.decode(Int.self, forKey: .v)
        ok = try? values.decodeIfPresent(Bool.self, forKey: .ok)
        // A check that does not decode is left out, not the whole list.
        let raw = (try? values.decodeIfPresent([Lossy<DoctorCheckJSON>].self, forKey: .checks)) ?? nil
        checks = raw?.compactMap(\.value) ?? []
        chip = try? values.decodeIfPresent(DoctorChipJSON.self, forKey: .chip)
        disk = try? values.decodeIfPresent(DoctorDiskJSON.self, forKey: .disk)
        macos = try? values.decodeIfPresent(DoctorMacOSJSON.self, forKey: .macos)
        memory = try? values.decodeIfPresent(DoctorMemoryJSON.self, forKey: .memory)
        entitlement = try? values.decodeIfPresent(DoctorEntitlementJSON.self, forKey: .entitlement)
        golden = try? values.decodeIfPresent(DoctorGoldenJSON.self, forKey: .golden)
        slots = try? values.decodeIfPresent(DoctorSlotsJSON.self, forKey: .slots)
        paddock = try? values.decodeIfPresent(DoctorPaddockJSON.self, forKey: .paddock)
        if raw == nil, chip == nil, disk == nil, macos == nil, memory == nil {
            throw DecodingError.dataCorruptedError(forKey: .checks, in: values,
                                                   debugDescription: "no checks and no chip, disk, macos or memory")
        }
    }
}

/// One line of the doctor report.
public struct DoctorCheckJSON: Codable, Equatable, Sendable {
    /// `apple_silicon`, `macos`, `free_space`, `memory`, `entitlement`,
    /// `slots`, or a check this launcher does not know yet.
    public var id: String
    /// `ok`, `warn` or `fail`. A word this launcher does not know is shown
    /// as a warning.
    public var level: String
    /// paddock's line, shown verbatim. For `fail` it says what to do.
    public var text: String

    public init(id: String, level: String, text: String) {
        self.id = id
        self.level = level
        self.text = text
    }
}

public struct DoctorChipJSON: Codable, Equatable, Sendable {
    public var appleSilicon: Bool
    public var name: String?

    public init(appleSilicon: Bool, name: String? = nil) {
        self.appleSilicon = appleSilicon
        self.name = name
    }
}

public struct DoctorDiskJSON: Codable, Equatable, Sendable {
    /// The macvm folder.
    public var dir: String?
    public var free: Int64
    public var need: Int64
    public var ok: Bool?

    public init(dir: String? = nil, free: Int64, need: Int64, ok: Bool? = nil) {
        self.dir = dir
        self.free = free
        self.need = need
        self.ok = ok
    }
}

public struct DoctorMacOSJSON: Codable, Equatable, Sendable {
    /// `27.2`.
    public var version: String
    public var minMajor: Int?
    public var ok: Bool

    public init(version: String, minMajor: Int? = nil, ok: Bool) {
        self.version = version
        self.minMajor = minMajor
        self.ok = ok
    }
}

public struct DoctorMemoryJSON: Codable, Equatable, Sendable {
    public var bytes: Int64
    public var defaultMib: Int64?
    public var perAppMaxMib: Int64?

    public init(bytes: Int64, defaultMib: Int64? = nil, perAppMaxMib: Int64? = nil) {
        self.bytes = bytes
        self.defaultMib = defaultMib
        self.perAppMaxMib = perAppMaxMib
    }
}

public struct DoctorEntitlementJSON: Codable, Equatable, Sendable {
    /// The path of `paddock-vm`.
    public var helper: String?
    public var present: Bool
}

public struct DoctorGoldenJSON: Codable, Equatable, Sendable {
    /// The `macvm status` golden word: `missing`, `sealed`, a build step.
    public var state: String
}

public struct DoctorSlotsJSON: Codable, Equatable, Sendable {
    /// One entry per VM slot: who holds it, or null.
    public var holders: [String?]?
    public var total: Int?
    public var used: Int?
}

public struct DoctorPaddockJSON: Codable, Equatable, Sendable {
    public var version: String?
}

/// An element of a list that is nil when it does not decode, so one bad
/// element does not fail the list.
struct Lossy<T: Decodable>: Decodable {
    var value: T?
    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

/// Where `paddock doctor --json` stands for the checklist.
public enum DoctorPhase: Equatable, Sendable {
    case checking
    case report(DoctorJSON)
    /// No answer within `DoctorPhase.limits`: the child was killed.
    case noAnswer
    /// paddock answered, but with no report: its last line.
    case failed(String)

    /// The time limit of the doctor and of the add precheck. A Mac that
    /// is busy answers both within a few seconds.
    public static let limits = RunLimits(seconds: 20, maxBytes: 1 << 20)

    public var report: DoctorJSON? {
        if case .report(let doctor) = self { return doctor }
        return nil
    }

    /// Runs the doctor and maps every outcome to a phase, so a failed or
    /// silent paddock never looks like a check that still runs.
    public static func run(_ service: PaddockService) async -> DoctorPhase {
        do {
            return .report(try await service.doctor())
        } catch CommandError.timedOut {
            return .noAnswer
        } catch {
            return .failed(LauncherStore.line(of: error))
        }
    }
}

public struct PrecheckJSON: Codable, Equatable, Sendable {
    public var v: Int
    public var ok: Bool
    public var name: String
    public var version: String?
    public var sizeBytes: Int64?
    public var appStore: Bool?
    /// The maker's site when paddock's profile knows it.
    public var website: String?
    /// `none`, `building`, `ready`.
    public var golden: String?
    public var needBytes: Int64?
    public var freeBytes: Int64?
    public var memoryOptionsGb: [Int]?
    public var message: String?
}

/// The answer of a command that changes something. `ok` false carries the
/// reason in one of the optional fields.
public struct ResultJSON: Codable, Equatable, Sendable {
    public var v: Int
    public var ok: Bool
    public var error: String?
    /// A share or rule paddock refuses, with paddock's line.
    public var refused: String?
    /// A folder with a `.env` or key file: paddock's line in `message`.
    public var needsUnprotected: Bool?
    public var message: String?
    /// `live`, `next_start`, `reopen`.
    public var applies: String?
    public var share: ShareJSON?
    public var rule: RuleJSON?
    public var freedBytes: Int64?
    public var launchpadName: String?
    /// `app run` refusals: `two_vms`, `low_disk`, `app_store`, `no_golden`.
    public var code: String?
    public var running: [String]?
    public var needBytes: Int64?
    public var freeBytes: Int64?
    public var openHandles: Int?
    /// `macvm latest`: the newest macOS paddock can build.
    public var latest: String?
    public var current: String?

    public init(v: Int = 1, ok: Bool) {
        self.v = v
        self.ok = ok
    }
}
