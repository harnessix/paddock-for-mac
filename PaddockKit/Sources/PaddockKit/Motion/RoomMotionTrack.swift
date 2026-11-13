import Foundation

// The motion of one room: the world goes in, the frame to draw comes out.
// A track holds the world of now and the moves that still run. The frame
// is a function of the time, so a fake clock can ask for any moment, and
// a frozen moment draws the same picture every time.

/// How much a room may move.
public enum RoomMotionMode: Equatable, Sendable {
    /// The full motion.
    case full
    /// Reduce Motion: the state swaps at once, under a short cross-fade.
    case reduced
    /// No motion and no work: the window is hidden, the room is off
    /// screen, or a UI test runs.
    case none

    public static func of(windowVisible: Bool, onScreen: Bool, reduceMotion: Bool, still: Bool = false) -> RoomMotionMode {
        if still || !windowVisible || !onScreen { return .none }
        return reduceMotion ? .reduced : .full
    }
}

/// Everything the motion layer draws in one room at one moment. All the
/// parts are plain numbers: 0 is the rest state of a part that is away,
/// 1 the rest state of a part that is there.
public struct RoomMotionFrame: Equatable, Sendable {
    /// The loop the character plays.
    public var pose: CharacterPose
    /// The loop it leaves, while the two cross-fade (the sleep mask goes
    /// up or down). Nil when only `pose` shows.
    public var fromPose: CharacterPose?
    /// How much of `pose` shows over `fromPose`, 0 to 1.
    public var poseBlend: Double
    /// Not nil in a frozen room: the loop holds the frame of this date.
    public var heldAt: Date?

    /// The way to the door: 0 at the desk, 1 at the door.
    public var walk: Double
    /// The height of the walking step, 0 to 1.
    public var step: Double
    /// The amber card in the hand of the character, 0 to 1.
    public var card: Double
    /// The part of the request time that is left, 1 to 0. Nil: no ring.
    public var ring: Double?

    /// How far the blind of the window is down, 0 to 1.
    public var shade: Double

    /// True when the room has a mailbox.
    public var mailbox: Bool
    /// The flag of the mailbox: 0 down, 1 up.
    public var flag: Double
    /// The height of the hop of the mailbox, 0 to 1.
    public var hop: Double

    /// The frost: 0 none, 1 grown from all four corners.
    public var frost: Double

    /// True when the room has a loft and a ladder.
    public var hasLoft: Bool
    /// The way to the loft: 0 on the floor, 1 at the desk of the loft.
    public var climb: Double
    /// The view: 0 looks at the room, 1 at the loft.
    public var pan: Double
    /// The notebooks on the shelf.
    public var notebooks: Int
    /// The newest notebook: 0 off the shelf, 1 in its place.
    public var notebookSlide: Double

    /// True when the room has a device cable.
    public var device: Bool
    /// True when the socket of the cable is covered.
    public var covered: Bool
    /// The spark on the cable: 0 at the room, 1 at the socket. Nil: none.
    public var spark: Double?
    /// The card over a covered socket: 0 down, 1 risen.
    public var deviceCard: Double

    /// The child room at the end of the path: 0 none, 1 built.
    public var build: Double
    /// The envelope on the path: 0 at the child, 1 at home. Nil: none.
    public var envelope: Double?

    /// The glow of the model on the desk, 0 to 1.
    public var glow: Double
    /// The parts on their way from the desk to the house, 0 to 1. Nil: none.
    public var apply: Double?

    /// The room light: 0 off, 1 on.
    public var light: Double

    /// True while the character is between two places.
    public var isWalking: Bool {
        (walk > 0 && walk < 1) || (climb > 0 && climb < 1)
    }

    /// The breath of the glow at `date`: a slow swell between 0.7 and 1.
    /// The view multiplies the glow with it, unless Reduce Motion is on.
    public static func breath(at date: Date) -> Double {
        let period = 2.4
        let phase = date.timeIntervalSince(SpritePlayer.epoch).truncatingRemainder(dividingBy: period) / period
        return 0.85 + 0.15 * sin(2 * Double.pi * phase)
    }
}

/// A frame, and with Reduce Motion the frame it cross-fades from.
public struct RoomMotionSnapshot: Equatable, Sendable {
    public var frame: RoomMotionFrame
    /// The frame before the change, under `frame`. Nil: no cross-fade.
    public var previous: RoomMotionFrame?
    /// How much of `frame` shows, 0 to 1.
    public var fade: Double

    public init(frame: RoomMotionFrame, previous: RoomMotionFrame? = nil, fade: Double = 1) {
        self.frame = frame
        self.previous = previous
        self.fade = fade
    }
}

public struct RoomMotionTrack: Equatable, Sendable {
    /// The parts that go from one level to another and stay there.
    enum Level: String, CaseIterable, Sendable {
        case walk, card, shade, flag, frost, climb, pan, deviceCard, build, glow, light, pose
    }

    /// The parts that happen once and are gone.
    enum Beat: String, CaseIterable, Sendable {
        case hop, notebook, spark, envelope, apply
    }

    struct Tween: Equatable, Sendable {
        var from: Double
        var to: Double
        var start: Date
        var motion: WorldMotion

        var end: Date { start.addingTimeInterval(motion.duration) }

        /// A date has a grain of a tenth of a microsecond, so the end is
        /// asked by date: from there the value is exactly `to`.
        func value(at date: Date) -> Double {
            if date >= end { return to }
            return from + (to - from) * motion.progress(date.timeIntervalSince(start))
        }
    }

    struct Pulse: Equatable, Sendable {
        var start: Date
        var motion: WorldMotion

        var end: Date { start.addingTimeInterval(motion.duration) }

        /// The place of the beat, or nil before its start and from its end.
        func progress(at date: Date) -> Double? {
            guard date >= start, date < end else { return nil }
            return motion.progress(date.timeIntervalSince(start))
        }
    }

    struct Held: Equatable, Sendable {
        var pose: CharacterPose
        var at: Date
    }

    struct Fade: Equatable, Sendable {
        var from: RoomMotionFrame
        var start: Date

        var end: Date { start.addingTimeInterval(WorldMotion.reducedFade) }
    }

    /// The world and the pose of now: what the room shows when all
    /// motion ended.
    public private(set) var world: RoomWorld
    public private(set) var pose: CharacterPose
    var tweens: [Level: Tween] = [:]
    var pulses: [Beat: Pulse] = [:]
    /// The pose the character keeps while the room is frozen.
    var held: Held?
    /// The pose the character leaves in a cross-fade.
    var fromPose: CharacterPose?
    var fade: Fade?

    /// A room at rest in `world`.
    public init(world: RoomWorld, pose: CharacterPose) {
        self.world = world
        self.pose = pose
        if world.frozen { held = Held(pose: pose, at: SpritePlayer.epoch) }
    }

    // MARK: The world changes

    /// The room goes to `new`. With `.full` each part that changed moves
    /// from where it is now, so a change in the middle of a motion goes
    /// on from there. With `.reduced` the room swaps at once under a
    /// cross-fade. With `.none` it swaps at once and nothing runs.
    public mutating func set(_ new: RoomWorld, pose newPose: CharacterPose, at now: Date, mode: RoomMotionMode) {
        guard new != world || newPose != pose else { return }
        let before = frame(at: now)
        let old = world
        let oldPose = pose
        let shownPose = held?.pose ?? oldPose
        prune(at: now)

        var next: [Level: Tween] = mode == .full ? tweens : [:]
        var beats: [Beat: Pulse] = mode == .full ? pulses : [:]
        if mode == .full {
            let sparks = (new.device?.calls ?? 0) > (old.device?.calls ?? 0)
            for level in Level.allCases where level != .pose {
                let target = RoomMotionTrack.target(level, new)
                let running = tweens[level]
                guard target != (running?.to ?? RoomMotionTrack.target(level, old)) else { continue }
                let current = value(level, at: now)
                guard current != target else {
                    next[level] = nil
                    continue
                }
                var start = now
                // The card rises when the spark has reached the cover.
                if level == .deviceCard, target > current, sparks { start = now.addingTimeInterval(WorldMotion.spark.duration) }
                next[level] = Tween(from: current, to: target, start: start,
                                    motion: RoomMotionTrack.motion(level, rising: target > current))
            }
            if new.mail == .question, old.mail != .question { beats[.hop] = Pulse(start: now, motion: .boxHop) }
            if let loft = new.loft, let had = old.loft, loft.notebooks > had.notebooks {
                beats[.notebook] = Pulse(start: now, motion: .notebook)
            }
            if sparks { beats[.spark] = Pulse(start: now, motion: .spark) }
            if old.child, !new.child { beats[.envelope] = Pulse(start: now, motion: .envelope) }
            if new.applied > old.applied { beats[.apply] = Pulse(start: now, motion: .apply) }
        }

        // The pose. A frozen character keeps the pose it had; the pose of
        // the state shows again when the room thaws.
        var nextHeld = held
        if new.frozen, !old.frozen { nextHeld = Held(pose: shownPose, at: now) }
        if !new.frozen { nextHeld = nil }
        let nextShown = nextHeld?.pose ?? newPose
        var nextFrom = mode == .full ? fromPose : nil
        if nextShown != shownPose {
            if mode == .full {
                nextFrom = shownPose
                next[.pose] = Tween(from: 0, to: 1, start: now, motion: .wake)
            } else {
                next[.pose] = nil
            }
        }

        world = new
        pose = newPose
        tweens = next
        pulses = beats
        held = nextHeld
        fromPose = nextFrom
        fade = mode == .reduced ? Fade(from: before, start: now) : nil
    }

    /// Ends every move now: the room is at rest in its world. A frozen
    /// character still keeps its pose. A room that goes off screen or
    /// whose window hides settles, so no half-done move waits for it.
    public mutating func settle() {
        tweens = [:]
        pulses = [:]
        fromPose = nil
        fade = nil
    }

    /// Forgets the moves that ended before `now`.
    mutating func prune(at now: Date) {
        tweens = tweens.filter { $0.value.end > now }
        pulses = pulses.filter { $0.value.end > now }
        if tweens[.pose] == nil { fromPose = nil }
        if let fade, fade.end <= now { self.fade = nil }
    }

    // MARK: The frame of a moment

    /// When the last move ends. Nil: the room is at rest.
    public var motionEnd: Date? {
        var end: Date?
        for date in tweens.values.map(\.end) + pulses.values.map(\.end) + (fade.map { [$0.end] } ?? []) {
            end = end.map { max($0, date) } ?? date
        }
        return end
    }

    public func isMoving(at date: Date) -> Bool {
        motionEnd.map { date < $0 } ?? false
    }

    /// True when the frame changes with the time while the room rests: a
    /// ring that runs down, or a glow that breathes.
    public func isAmbient(at date: Date) -> Bool {
        let frame = frame(at: date)
        return (frame.ring ?? 0) > 0 || frame.glow > 0
    }

    func value(_ level: Level, at date: Date) -> Double {
        tweens[level]?.value(at: date) ?? RoomMotionTrack.target(level, world)
    }

    public func frame(at date: Date) -> RoomMotionFrame {
        let walk = value(.walk, at: date)
        let climb = value(.climb, at: date)
        let moving = (walk > 0 && walk < 1) || (climb > 0 && climb < 1)

        var shown = held?.pose ?? pose
        var from: CharacterPose?
        var blend = 1.0
        if held == nil, moving {
            // Between two places the character is awake and on its feet.
            shown = .idle
        } else if held == nil, climb >= 1 {
            // In the loft it writes.
            shown = .work
        } else if let tween = tweens[.pose], let fromPose, date < tween.end {
            from = fromPose
            blend = tween.value(at: date)
        }

        let hop = pulses[.hop]?.progress(at: date).map { sin(Double.pi * $0) } ?? 0
        let slide = pulses[.notebook]?.progress(at: date) ?? 1
        let stop = world.device?.covered == true ? RoomPlaces.sparkStop : 1
        return RoomMotionFrame(
            pose: shown, fromPose: from, poseBlend: blend, heldAt: world.frozen ? held?.at : nil,
            walk: walk, step: abs(sin(Double.pi * RoomPlaces.steps * walk)), card: value(.card, at: date),
            ring: walk >= 1 ? world.request?.left(at: date) : nil,
            shade: value(.shade, at: date),
            mailbox: world.mail != nil, flag: value(.flag, at: date), hop: hop,
            frost: value(.frost, at: date),
            hasLoft: world.loft != nil, climb: climb, pan: value(.pan, at: date),
            notebooks: world.loft?.notebooks ?? 0, notebookSlide: slide,
            device: world.device != nil, covered: world.device?.covered ?? false,
            spark: pulses[.spark]?.progress(at: date).map { $0 * stop },
            deviceCard: value(.deviceCard, at: date),
            build: value(.build, at: date), envelope: pulses[.envelope]?.progress(at: date),
            glow: value(.glow, at: date), apply: pulses[.apply]?.progress(at: date),
            light: value(.light, at: date))
    }

    /// The frame of `date`, and with Reduce Motion the frame under it
    /// while the two cross-fade.
    public func snapshot(at date: Date) -> RoomMotionSnapshot {
        let frame = frame(at: date)
        guard let fade, date < fade.end else { return RoomMotionSnapshot(frame: frame) }
        let progress = min(1, max(0, date.timeIntervalSince(fade.start) / WorldMotion.reducedFade))
        return RoomMotionSnapshot(frame: frame, previous: fade.from, fade: progress)
    }

    // MARK: The rest states

    /// Where a part rests in `world`.
    static func target(_ level: Level, _ world: RoomWorld) -> Double {
        switch level {
        case .walk, .card: return world.request != nil ? 1 : 0
        case .shade: return world.network?.shade ?? 0
        case .flag: return world.mail == .message || world.mail == .question ? 1 : 0
        case .frost: return world.frozen ? 1 : 0
        case .climb: return world.characterInLoft ? 1 : 0
        case .pan: return world.looksAtLoft ? 1 : 0
        case .deviceCard: return world.device.map { $0.covered && $0.calls > 0 } == true ? 1 : 0
        case .build: return world.child ? 1 : 0
        case .glow: return world.changes ? 1 : 0
        case .light: return world.lit ? 1 : 0
        case .pose: return 1
        }
    }

    /// The motion that takes a part up or down.
    static func motion(_ level: Level, rising: Bool) -> WorldMotion {
        switch level {
        case .walk: return rising ? .requestOut : .requestBack
        case .card: return .requestCard
        case .shade: return .network
        case .flag: return rising ? .flagUp : .flagDown
        case .frost: return rising ? .freeze : .thaw
        case .climb: return rising ? .climb : .descend
        case .pan: return .loftPan
        case .deviceCard: return .deviceCard
        case .build: return rising ? .spawn : .envelope
        case .glow: return .glow
        case .light: return rising ? .lightOn : .lightOff
        case .pose: return .wake
        }
    }
}

// MARK: - Ticks

/// The moments a room draws again, from `from` on: the first is `from`
/// itself. While a motion runs, the room draws at `WorldMotion.fps` and
/// the sprite loop changes its frame on those ticks, so a room never
/// draws more than 30 times a second. Then the sprite loop ticks on the
/// shared grid of `SpritePlayer.aligned`, if it plays. A room with no
/// loop and no motion has one tick: it draws once.
public struct RoomTicks: Sequence, IteratorProtocol, Equatable, Sendable {
    let from: Date
    /// The start of the sprite loop on the shared grid. Nil: no loop.
    let sprite: Date?
    let motionEnd: Date?
    /// A tick a second, for a ring that runs down with Reduce Motion.
    let slow: Bool
    private var last: Date?
    // The ticks count in whole numbers: a date has a grain of a tenth of
    // a microsecond, too coarse to find the place in a stream again.
    private var motionIndex = 0
    private var motionDone = false
    private var spriteIndex = 0
    private var slowIndex = 0
    /// Two ticks nearer than this are one tick.
    static let grain = 1e-4

    public init(from: Date, sprite: Date?, motionEnd: Date?, slow: Bool = false) {
        self.from = from
        self.sprite = sprite
        self.motionEnd = motionEnd.flatMap { $0 > from ? $0 : nil }
        self.slow = slow
    }

    /// The ticks of a room in `mode`. `plays` is true when the sprite
    /// loop plays or the frame is ambient.
    public static func of(_ track: RoomMotionTrack, from: Date, spriteStart: Date, plays: Bool, mode: RoomMotionMode) -> RoomTicks {
        switch mode {
        case .none:
            return RoomTicks(from: from, sprite: nil, motionEnd: nil)
        case .reduced:
            return RoomTicks(from: from, sprite: nil, motionEnd: track.motionEnd,
                             slow: track.frame(at: from).ring != nil)
        case .full:
            let ambient = track.isAmbient(at: from) || track.world.request != nil || track.world.changes
            return RoomTicks(from: from, sprite: plays || ambient ? spriteStart : nil, motionEnd: track.motionEnd)
        }
    }

    public mutating func next() -> Date? {
        guard let last else {
            self.last = from
            return from
        }
        if let motionEnd, !motionDone {
            // The next tick of the motion; the last one is its end, so
            // the room draws its rest state.
            motionIndex += 1
            var tick = from.addingTimeInterval(Double(motionIndex) / WorldMotion.fps)
            if tick >= motionEnd.addingTimeInterval(-RoomTicks.grain) {
                tick = motionEnd
                motionDone = true
            }
            self.last = tick
            return tick
        }
        var best: Date?
        if let sprite {
            func tick(_ index: Int) -> Date { sprite.addingTimeInterval(Double(index) / SpritePlayer.fps) }
            while tick(spriteIndex) <= last.addingTimeInterval(RoomTicks.grain) { spriteIndex += 1 }
            best = tick(spriteIndex)
        }
        if slow {
            func tick(_ index: Int) -> Date { from.addingTimeInterval(Double(index)) }
            while tick(slowIndex) <= last.addingTimeInterval(RoomTicks.grain) { slowIndex += 1 }
            best = best.map { Swift.min($0, tick(slowIndex)) } ?? tick(slowIndex)
        }
        guard let best else { return nil }
        self.last = best
        return best
    }
}
