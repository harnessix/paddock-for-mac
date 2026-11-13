import Foundation

/// What paddock does in a room, apart from the pose of the character: the
/// state that goes into the motion layer. A view gives the world of now;
/// the motion layer moves the room from the world before to this one.
/// Every part has a default that draws nothing, so a room with no agent
/// facts is the plain room.
public struct RoomWorld: Equatable, Sendable {
    /// A request that waits for an answer at the door.
    public struct Request: Equatable, Sendable {
        /// When the agent asked, and when the request ends. With both, the
        /// waiting character has a ring for the time left.
        public var created: Date?
        public var expires: Date?

        public init(created: Date? = nil, expires: Date? = nil) {
            self.created = created
            self.expires = expires
        }

        /// The part of the time that is left at `date`, 1 to 0. Nil when
        /// the request has no time limit.
        public func left(at date: Date) -> Double? {
            guard let created, let expires else { return nil }
            let whole = expires.timeIntervalSince(created)
            guard whole > 0 else { return nil }
            return min(1, max(0, expires.timeIntervalSince(date) / whole))
        }
    }

    /// The network of the room, shown by the blind of the window.
    public enum Network: String, CaseIterable, Equatable, Sendable {
        /// The internet: the blind is up.
        case open
        /// Some servers only: the blind is half down.
        case limited
        /// No network: the blind is down.
        case closed

        /// How far the blind is down, 0 to 1.
        public var shade: Double {
            switch self {
            case .open: return 0
            case .limited: return 0.5
            case .closed: return 1
            }
        }

        /// paddock's word for the network of a run. An unknown word is
        /// nil: the window stays as the art draws it.
        public static func of(_ word: String?) -> Network? {
            switch word?.lowercased() {
            case "none", "off", "offline", "closed": return .closed
            case "api", "allowlist", "limited", "ask", "rules": return .limited
            case "egress", "host", "open", "internet", "on": return .open
            default: return nil
            }
        }
    }

    /// The mailbox of the run.
    public enum Mail: String, CaseIterable, Equatable, Sendable {
        /// Nothing new: the flag is down.
        case empty
        /// A message waits: the flag is up.
        case message
        /// A question waits: the flag is up, and the box hopped once.
        case question
    }

    /// The loft over the room: the notebooks of the agent.
    public struct Loft: Equatable, Sendable {
        /// The notebooks on the shelf.
        public var notebooks: Int
        /// True while the agent writes a note: the character is up there.
        public var writing: Bool

        public init(notebooks: Int = 0, writing: Bool = false) {
            self.notebooks = notebooks
            self.writing = writing
        }
    }

    /// The device cable of the Plumbing view.
    public struct Device: Equatable, Sendable {
        /// The calls so far. Each new call sends one spark.
        public var calls: Int
        /// True when the socket is covered: the spark stops at the cover,
        /// and a card rises for your answer.
        public var covered: Bool

        public init(calls: Int = 0, covered: Bool = false) {
            self.calls = calls
            self.covered = covered
        }
    }

    /// True while the sandbox runs: the room light is on.
    public var lit: Bool
    public var request: Request?
    /// Nil: the room does not say its network, the window stays clear.
    public var network: Network?
    /// Nil: the room has no mailbox.
    public var mail: Mail?
    /// True while the sandbox is frozen: frost covers the room.
    public var frozen: Bool
    /// Nil: the room has no loft and no ladder.
    public var loft: Loft?
    /// True while the view looks at the loft, whatever the character does.
    public var showsLoft: Bool
    /// Nil: no device cable.
    public var device: Device?
    /// True while a run that this run spawned lives.
    public var child: Bool
    /// True while changes wait in the copy: the model on the desk glows.
    public var changes: Bool
    /// The applies so far. Each new one moves the parts to the house.
    public var applied: Int

    public init(lit: Bool = true, request: Request? = nil, network: Network? = nil, mail: Mail? = nil,
                frozen: Bool = false, loft: Loft? = nil, showsLoft: Bool = false, device: Device? = nil,
                child: Bool = false, changes: Bool = false, applied: Int = 0) {
        self.lit = lit
        self.request = request
        self.network = network
        self.mail = mail
        self.frozen = frozen
        self.loft = loft
        self.showsLoft = showsLoft
        self.device = device
        self.child = child
        self.changes = changes
        self.applied = applied
    }

    /// True when the character is in the loft. A request wins: the
    /// character waits at the door.
    public var characterInLoft: Bool {
        request == nil && loft?.writing == true
    }

    /// True when the view looks at the loft.
    public var looksAtLoft: Bool {
        loft != nil && (showsLoft || characterInLoft)
    }
}

// MARK: - The world of a room

extension RoomWorld {
    /// The world of a room that only has a scene: the light is on unless
    /// the character sleeps. A waiting character stays at its desk: only
    /// a room that says it has a request sends it to the door.
    public static func of(_ scene: RoomScene) -> RoomWorld {
        RoomWorld(lit: scene.pose != .sleep)
    }

    /// The world of an app: the light follows the session, a suspended
    /// session is frozen, and an open network question is a request.
    public static func of(_ app: AppItem, questions: Int) -> RoomWorld {
        var world = RoomWorld()
        switch app.state {
        case .running, .starting:
            world.lit = true
        case .stopped, .saved, .stopping, .suspended:
            world.lit = false
        case .error, .blocked:
            world.lit = true
        }
        if case .suspended = app.state { world.frozen = true }
        if questions > 0, RoomScene.pose(app.state, questions: questions) == .wait {
            world.request = Request()
        }
        return world
    }

    /// The world of an agent run: the light while the run lives, the
    /// oldest request at the door, the network at the window, and the
    /// model that glows while the run has changed files. `children` is
    /// the number of live runs this run spawned. A newer paddock adds the
    /// mailbox (a question hops it), the loft (a commit sends the
    /// character up) and the device cable (a call sends a spark).
    public static func of(_ room: AgentRoom, children: Int = 0) -> RoomWorld {
        var world = RoomWorld(lit: room.state.isLive)
        if case .waiting = room.state {
            let oldest = room.requests.min { ($0.created ?? .distantFuture) < ($1.created ?? .distantFuture) }
            world.request = Request(created: oldest?.created, expires: oldest?.expires)
        }
        world.network = Network.of(room.network)
        world.changes = room.state.isLive && (room.filesChanged ?? 0) > 0
        world.child = children > 0
        // The facts of a newer paddock. Without them the room has no
        // mailbox, no loft and no cable: no motion, nothing missing.
        world.mail = room.unreadAsks.map { $0 > 0 ? .question : .empty }
        world.loft = room.loftCommits.map { Loft(notebooks: $0, writing: room.loftWriting && room.state.isLive) }
        world.device = room.device?.world
        return world
    }
}
