import Foundation

/// One motion from its start to its end, for a frozen frame of a snapshot
/// and for the tests: the world before, the world after, and the track
/// that goes from one to the other.
public struct MotionDemo: Equatable, Sendable {
    public var motion: WorldMotion
    public var from: RoomWorld
    public var fromPose: CharacterPose
    public var to: RoomWorld
    public var toPose: CharacterPose

    /// The start of every demo: a fixed moment on the sprite grid.
    public static let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// The demo of a motion in a room. Nil for the motions between views
    /// (`roomless`): they have no world, only a progress.
    public static func of(_ motion: WorldMotion) -> MotionDemo? {
        let request = RoomWorld.Request(created: start, expires: start.addingTimeInterval(300))
        func demo(_ from: RoomWorld, _ fromPose: CharacterPose, _ to: RoomWorld, _ toPose: CharacterPose) -> MotionDemo {
            MotionDemo(motion: motion, from: from, fromPose: fromPose, to: to, toPose: toPose)
        }
        let loft = RoomWorld.Loft(notebooks: 3)
        switch motion {
        case .requestOut, .requestCard:
            return demo(RoomWorld(), .work, RoomWorld(request: request), .wait)
        case .requestBack:
            return demo(RoomWorld(request: request), .wait, RoomWorld(), .work)
        case .network:
            return demo(RoomWorld(network: .open), .work, RoomWorld(network: .closed), .work)
        case .flagUp:
            return demo(RoomWorld(mail: .empty), .work, RoomWorld(mail: .message), .work)
        case .flagDown:
            return demo(RoomWorld(mail: .message), .work, RoomWorld(mail: .empty), .work)
        case .boxHop:
            return demo(RoomWorld(mail: .empty), .work, RoomWorld(mail: .question), .work)
        case .freeze:
            return demo(RoomWorld(), .work, RoomWorld(lit: false, frozen: true), .sleep)
        case .thaw:
            return demo(RoomWorld(lit: false, frozen: true), .sleep, RoomWorld(), .work)
        case .climb:
            return demo(RoomWorld(loft: loft), .work, RoomWorld(loft: RoomWorld.Loft(notebooks: 3, writing: true)), .work)
        case .descend:
            return demo(RoomWorld(loft: RoomWorld.Loft(notebooks: 3, writing: true)), .work, RoomWorld(loft: loft), .work)
        case .notebook:
            return demo(RoomWorld(loft: RoomWorld.Loft(notebooks: 3, writing: true)), .work,
                        RoomWorld(loft: RoomWorld.Loft(notebooks: 4, writing: true)), .work)
        case .spark:
            return demo(RoomWorld(device: RoomWorld.Device()), .work, RoomWorld(device: RoomWorld.Device(calls: 1)), .work)
        case .deviceCard:
            return demo(RoomWorld(device: RoomWorld.Device(covered: true)), .work,
                        RoomWorld(device: RoomWorld.Device(calls: 1, covered: true)), .work)
        case .spawn:
            return demo(RoomWorld(), .work, RoomWorld(child: true), .work)
        case .envelope:
            return demo(RoomWorld(child: true), .work, RoomWorld(), .work)
        case .glow:
            return demo(RoomWorld(), .work, RoomWorld(changes: true), .work)
        case .apply:
            return demo(RoomWorld(changes: true), .work, RoomWorld(applied: 1), .work)
        case .loftPan:
            return demo(RoomWorld(loft: loft), .work, RoomWorld(loft: loft, showsLoft: true), .work)
        case .lightOn:
            return demo(RoomWorld(lit: false), .sleep, RoomWorld(), .idle)
        case .lightOff:
            return demo(RoomWorld(), .idle, RoomWorld(lit: false), .sleep)
        case .wake:
            return demo(RoomWorld(), .sleep, RoomWorld(), .idle)
        case .zoom, .cardEnter, .cardLeave, .hover:
            return nil
        }
    }

    /// The motions between views: a zoom, a card that comes or goes, the
    /// lift under the pointer.
    public static let roomless: [WorldMotion] = [.zoom, .cardEnter, .cardLeave, .hover]

    /// The track of the demo: at rest in `from`, then set to `to` at `start`.
    public func track(mode: RoomMotionMode = .full) -> RoomMotionTrack {
        var track = RoomMotionTrack(world: from, pose: fromPose)
        track.set(to, pose: toPose, at: MotionDemo.start, mode: mode)
        return track
    }

    /// The room at rest after the motion.
    public var rest: RoomMotionTrack {
        RoomMotionTrack(world: to, pose: toPose)
    }

    /// When the demo is at rest: the end of its track. The card of a
    /// covered socket rises after the spark, so this can be later than
    /// the length of the motion.
    public func end(mode: RoomMotionMode = .full) -> Date {
        track(mode: mode).motionEnd ?? MotionDemo.start
    }

    public func date(milliseconds: Int) -> Date {
        MotionDemo.start.addingTimeInterval(Double(milliseconds) / 1000)
    }
}

/// `PADDOCK_LAUNCHER_SNAPSHOT_MOTION=NAME@MS`: the motion NAME, frozen MS
/// milliseconds after its start. `request-out@250` is the character half
/// way to the door.
public struct MotionFreeze: Equatable, Sendable {
    public var motion: WorldMotion
    public var milliseconds: Int

    public init(motion: WorldMotion, milliseconds: Int) {
        self.motion = motion
        self.milliseconds = milliseconds
    }

    /// Reads `NAME@MS`. Nil for an unknown name, a missing time or a
    /// time that is no whole number from 0 up.
    public static func parse(_ text: String?) -> MotionFreeze? {
        guard let text else { return nil }
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, let motion = WorldMotion(rawValue: parts[0].lowercased()),
              let milliseconds = Int(parts[1]), milliseconds >= 0 else { return nil }
        return MotionFreeze(motion: motion, milliseconds: milliseconds)
    }

    /// The names a snapshot can ask for.
    public static var names: [String] { WorldMotion.allCases.map(\.rawValue) }

    /// The frozen moment.
    public var date: Date {
        MotionDemo.start.addingTimeInterval(Double(milliseconds) / 1000)
    }

    /// The place of the motion at the frozen moment, 0 to 1: what a
    /// motion between views draws.
    public var progress: Double {
        motion.progress(Double(milliseconds) / 1000)
    }

    /// The frozen frame of a room motion, with Reduce Motion or without.
    /// Nil for a motion between views.
    public func snapshot(mode: RoomMotionMode = .full) -> RoomMotionSnapshot? {
        MotionDemo.of(motion).map { $0.track(mode: mode).snapshot(at: date) }
    }
}
