import Foundation

// The motion of the paddock world: what moves in a room when paddock does
// something. This file names every motion and gives its length and its
// curve. The rules have no AppKit, so a fake clock tests them: a motion
// is a function of the time.

/// How a motion moves between its start (0) and its end (1).
public enum MotionCurve: Equatable, Sendable {
    case linear
    case easeIn
    case easeOut
    case easeInOut
    /// A damped spring that comes to rest at the end of the motion.
    /// `bounce` 0 has no overshoot; 0.15 goes a little past the end and
    /// comes back.
    case spring(bounce: Double)

    /// The place at the part `t` of the time, 0 to 1. The value is exactly
    /// 0 at the start and exactly 1 at the end; a spring can be a little
    /// over 1 between them.
    public func value(_ t: Double) -> Double {
        if t <= 0 { return 0 }
        if t >= 1 { return 1 }
        switch self {
        case .linear:
            return t
        case .easeIn:
            return t * t * t
        case .easeOut:
            return 1 - pow(1 - t, 3)
        case .easeInOut:
            return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
        case .spring(let bounce):
            let raw = MotionCurve.spring(t, bounce: bounce)
            // The spring is within a thousandth of 1 at the end; the rest
            // is spread over the motion, so the end is exact.
            return raw + (1 - MotionCurve.spring(1, bounce: bounce)) * t
        }
    }

    /// The step response of a spring whose envelope is gone at t = 1.
    static func spring(_ t: Double, bounce: Double) -> Double {
        let zeta = min(1, max(0.3, 1 - bounce))
        // The envelope e^(-decay t) is 0.0006 at the end.
        let decay = 7.5
        if zeta >= 0.999 {
            let omega = 9.5
            return 1 - exp(-omega * t) * (1 + omega * t)
        }
        let omega = decay / zeta
        let damped = omega * (1 - zeta * zeta).squareRoot()
        return 1 - exp(-decay * t) * (cos(damped * t) + decay / damped * sin(damped * t))
    }
}

/// Every motion of the world. The raw value is the name of the motion in
/// `PADDOCK_LAUNCHER_SNAPSHOT_MOTION=NAME@MS`.
public enum WorldMotion: String, CaseIterable, Equatable, Sendable {
    /// A request: the character walks to the door with an amber card.
    case requestOut = "request-out"
    /// The answer came: the character walks back to the desk.
    case requestBack = "request-back"
    /// The amber card comes into the hand, or goes.
    case requestCard = "request-card"
    /// The network mode changed: the blind of the window moves.
    case network
    /// A message came: the flag of the mailbox goes up.
    case flagUp = "flag-up"
    /// The messages are read: the flag goes down.
    case flagDown = "flag-down"
    /// A question came: the mailbox hops once.
    case boxHop = "box-hop"
    /// The room freezes: frost grows from the corners.
    case freeze
    /// The room thaws: the frost melts back to the corners.
    case thaw
    /// The character goes to the ladder and climbs to the loft.
    case climb
    /// The character comes down from the loft.
    case descend
    /// A new notebook slides onto the shelf of the loft.
    case notebook
    /// A device call: a spark runs along the cable.
    case spark
    /// The spark stopped at a covered socket: a card rises from it.
    case deviceCard = "device-card"
    /// A spawn: a child room builds at the end of a path.
    case spawn
    /// The child ended: an envelope comes back along the path.
    case envelope
    /// Changes wait in the copy: the model on the desk starts to glow.
    case glow
    /// Apply: the parts move from the desk to the house.
    case apply
    /// The rooms grid to one room: the room zooms.
    case zoom
    /// The room to its loft: the view pans up.
    case loftPan = "loft-pan"
    /// A card comes into the grid.
    case cardEnter = "card-enter"
    /// A card leaves the grid.
    case cardLeave = "card-leave"
    /// The pointer is over a card: the card lifts.
    case hover
    /// Start: the room light turns on.
    case lightOn = "light-on"
    /// Stop: the room light dims.
    case lightOff = "light-off"
    /// The character changes its pose: the sleep mask goes up or down.
    case wake

    /// The length of the motion in milliseconds.
    public var milliseconds: Int {
        switch self {
        case .requestOut: return 500
        case .requestBack: return 400
        case .requestCard: return 150
        case .network: return 300
        case .flagUp, .flagDown: return 200
        case .boxHop: return 320
        case .freeze, .thaw: return 600
        case .climb, .descend: return 600
        case .notebook: return 250
        case .spark: return 400
        case .deviceCard: return 250
        case .spawn: return 800
        case .envelope: return 500
        case .glow: return 300
        case .apply: return 700
        case .zoom: return 450
        case .loftPan: return 350
        case .cardEnter: return 220
        case .cardLeave: return 160
        case .hover: return 180
        case .lightOn, .lightOff: return 400
        case .wake: return 240
        }
    }

    public var duration: TimeInterval { Double(milliseconds) / 1000 }

    public var curve: MotionCurve {
        switch self {
        case .requestOut, .requestBack, .climb, .descend, .loftPan, .apply, .envelope:
            return .easeInOut
        case .requestCard, .network, .flagDown, .freeze, .thaw, .notebook, .deviceCard, .spawn, .glow,
             .cardEnter, .lightOn, .lightOff, .wake:
            return .easeOut
        case .cardLeave:
            return .easeIn
        case .spark, .boxHop:
            return .linear
        case .flagUp:
            return .spring(bounce: 0.25)
        case .zoom:
            return .spring(bounce: 0.12)
        case .hover:
            return .spring(bounce: 0)
        }
    }

    /// The place of the motion `elapsed` seconds after its start, 0 to 1.
    public func progress(_ elapsed: TimeInterval) -> Double {
        curve.value(elapsed / duration)
    }

    /// With Reduce Motion a change is a cross-fade of this length; the
    /// state itself swaps at once.
    public static let reducedFadeMilliseconds = 150
    public static var reducedFade: TimeInterval { Double(reducedFadeMilliseconds) / 1000 }

    /// The most frames a second a motion draws. The sprite loops stay at
    /// `SpritePlayer.fps`.
    public static let fps: Double = 30
    public static var frameInterval: TimeInterval { 1 / fps }

    /// No motion is longer than this: the world stays calm.
    public static let longestMilliseconds = 800
}
