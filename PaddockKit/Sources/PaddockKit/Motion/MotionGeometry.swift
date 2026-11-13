import Foundation

// Where the moving parts are. All places are in the pixels of a room
// image (512 square, y down), as rooms.json. The loft is a second square
// on top of the room: its pixels have a y from -512 to 0.

/// The places of the room that the motion uses, measured on the art.
public enum RoomPlaces {
    /// The side of a room image.
    public static let size = 512.0

    /// From the feet of the character at its desk to the floor in front
    /// of the door.
    public static let door = RoomPoint(x: -47, y: 5)
    /// The steps of the walk to the door.
    public static let steps = 3.0
    /// The height of one step.
    public static let stepHeight = 7.0

    /// From the feet at the desk to the foot of the ladder, to the hatch
    /// in the floor of the loft, and to the desk of the loft.
    public static let ladderFoot = RoomPoint(x: 135, y: -27)
    public static let hatch = RoomPoint(x: 135, y: -427)
    public static let loftSeat = RoomPoint(x: 62, y: -435)
    /// The parts of the climb: to the ladder, up the ladder, to the desk.
    public static let climbPath = MotionPath([(0, RoomPoint(x: 0, y: 0)), (0.22, ladderFoot), (0.88, hatch), (1, loftSeat)])

    /// The ladder: its foot on the floor and its top in the loft.
    public static let ladderBase = RoomPoint(x: 326, y: 268)
    public static let ladderTop = RoomPoint(x: 326, y: -150)
    public static let ladderWidth = 34.0

    /// The window on the right wall: top left, top right, bottom right,
    /// bottom left.
    public static let window = ScreenQuad(topLeft: RoomPoint(x: 366, y: 110), topRight: RoomPoint(x: 431, y: 141),
                                          bottomRight: RoomPoint(x: 431, y: 197), bottomLeft: RoomPoint(x: 366, y: 165))

    /// The post of the mailbox, outside by the door.
    public static let mailbox = RoomPoint(x: 62, y: 442)
    public static let hopHeight = 12.0

    /// The model of the project on the desk, and the house it stands
    /// for, outside over the door.
    public static let model = RoomPoint(x: 306, y: 291)
    public static let house = RoomPoint(x: 62, y: 40)

    /// The path to the child room: from the front corner of the room to
    /// the child, outside on the right.
    public static let pathStart = RoomPoint(x: 296, y: 462)
    public static let child = RoomPoint(x: 430, y: 440)

    /// The part of the cable a spark runs when the socket is covered: it
    /// stops at the cover.
    public static let sparkStop = 0.78

    /// Where the character is, from its place at the desk. A request
    /// wins over the loft.
    public static func characterOffset(_ frame: RoomMotionFrame) -> RoomPoint {
        if frame.climb > 0, frame.walk <= 0 { return climbPath.point(frame.climb) }
        return RoomPoint(x: door.x * frame.walk, y: door.y * frame.walk - stepHeight * frame.step)
    }

    /// The point `t` of the way from `a` to `b`, lifted by an arc of
    /// `height` in its middle: the flight of a part or an envelope.
    public static func arc(_ a: RoomPoint, _ b: RoomPoint, _ t: Double, height: Double) -> RoomPoint {
        RoomPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t - height * 4 * t * (1 - t))
    }
}

/// A way through some points; each point has the part of the way at
/// which the mover is there.
public struct MotionPath: Equatable, Sendable {
    public var stops: [Double]
    public var points: [RoomPoint]

    public init(_ pairs: [(Double, RoomPoint)]) {
        stops = pairs.map(\.0)
        points = pairs.map(\.1)
    }

    public func point(_ t: Double) -> RoomPoint {
        guard let first = points.first, let last = points.last else { return RoomPoint(x: 0, y: 0) }
        if t <= stops[0] { return first }
        for index in 1..<points.count where t <= stops[index] {
            let span = stops[index] - stops[index - 1]
            let part = span > 0 ? (t - stops[index - 1]) / span : 1
            let a = points[index - 1], b = points[index]
            return RoomPoint(x: a.x + (b.x - a.x) * part, y: a.y + (b.y - a.y) * part)
        }
        return last
    }
}

/// A rectangle in the points of a window.
public struct MotionRect: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
}

/// The zoom from a card of the grid to the room of the detail: the room
/// of the detail starts at the place and the size of the card and comes
/// to its own.
public struct ZoomTransform: Equatable, Sendable {
    public var scale: Double
    public var x: Double
    public var y: Double

    public static let identity = ZoomTransform(scale: 1, x: 0, y: 0)

    public init(scale: Double, x: Double, y: Double) {
        self.scale = scale
        self.x = x
        self.y = y
    }

    /// The scale about the middle of `to` and the offset that draw a view
    /// of the frame `to` at `from` when `progress` is 0, and at its own
    /// place when it is 1. A spring can pass 1 a little.
    public static func of(from: MotionRect, to: MotionRect, progress: Double) -> ZoomTransform {
        guard to.width > 0, from.width > 0 else { return .identity }
        let rest = 1 - progress
        return ZoomTransform(scale: 1 + (from.width / to.width - 1) * rest,
                             x: (from.midX - to.midX) * rest, y: (from.midY - to.midY) * rest)
    }

    /// The start of the zoom when the card is not known: the room is a
    /// little smaller.
    public static func plain(progress: Double) -> ZoomTransform {
        ZoomTransform(scale: 1 + (CardMotion.zoomFallbackScale - 1) * (1 - progress), x: 0, y: 0)
    }
}

/// How a card comes, goes and answers the pointer.
public enum CardMotion {
    /// A card that comes in grows from this scale; one that leaves
    /// shrinks to `leaveScale`.
    public static let enterScale = 0.94
    public static let leaveScale = 0.96
    /// The lift of a card under the pointer, in points, and its growth.
    public static let hoverLift = 2.0
    public static let hoverScale = 1.012
    public static let zoomFallbackScale = 0.82

    /// The scale and the opacity of a card `progress` into its entry.
    public static func entering(_ progress: Double) -> (scale: Double, opacity: Double) {
        (enterScale + (1 - enterScale) * progress, min(1, max(0, progress)))
    }

    /// The scale and the opacity of a card `progress` into its leave.
    public static func leaving(_ progress: Double) -> (scale: Double, opacity: Double) {
        (1 + (leaveScale - 1) * progress, min(1, max(0, 1 - progress)))
    }

    /// The lift and the scale of a card `progress` into the hover.
    public static func hover(_ progress: Double) -> (lift: Double, scale: Double) {
        (hoverLift * progress, 1 + (hoverScale - 1) * progress)
    }
}
