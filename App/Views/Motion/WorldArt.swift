import PaddockKit
import SwiftUI

// The small parts of the world that the room art does not have: the
// amber card, the ring, the blind, the mailbox, the frost, the ladder and
// the loft, the model and the house, the child room, the envelope. They
// are drawn with shapes in the style of the art: flat fills and a dark
// outline with round corners. All places are in the pixels of a room
// image (512 square, `RoomPlaces`), so a part sits on the art at any size.

/// The colors and the strokes of the drawn parts.
enum WorldArt {
    /// The outline color of the art.
    static let ink = Color(red: RoomStage.ink.red, green: RoomStage.ink.green, blue: RoomStage.ink.blue)
    /// The amber of the "!" bubble of the wait loop.
    static let amber = Color(red: 0.95, green: 0.69, blue: 0.24)
    static let amberLight = Color(red: 0.99, green: 0.87, blue: 0.55)
    static let paper = Color(red: 0.99, green: 0.98, blue: 0.95)
    static let cream = Color(red: 0.98, green: 0.93, blue: 0.82)
    static let wood = Color(red: 0.76, green: 0.54, blue: 0.33)
    static let woodDark = Color(red: 0.58, green: 0.39, blue: 0.23)
    static let glass = Color(red: 0.78, green: 0.93, blue: 0.99)
    static let ice = Color(red: 0.88, green: 0.95, blue: 1.0)
    static let flag = Color(red: 0.91, green: 0.36, blue: 0.32)
    static let box = Color(red: 0.45, green: 0.62, blue: 0.88)
    static let roof = Color(red: 0.89, green: 0.45, blue: 0.36)
    /// The covers of the notebooks, in shelf order.
    static let notebooks: [Color] = [
        Color(red: 0.95, green: 0.69, blue: 0.24), Color(red: 0.40, green: 0.63, blue: 0.95),
        Color(red: 0.95, green: 0.56, blue: 0.71), Color(red: 0.42, green: 0.80, blue: 0.54),
        Color(red: 0.66, green: 0.53, blue: 0.93), Color(red: 0.31, green: 0.76, blue: 0.75),
    ]
    /// The most notebooks the shelf shows.
    static let shelfRoom = 7

    /// The width of the outline, in room pixels.
    static let line: CGFloat = 5

    static func point(_ p: RoomPoint) -> CGPoint {
        CGPoint(x: p.x, y: p.y)
    }

    static func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }

    static func polygon(_ points: [CGPoint]) -> Path {
        Path { path in
            path.addLines(points)
            path.closeSubpath()
        }
    }

    /// Fills `path` and draws the outline of the art around it.
    static func toon(_ context: GraphicsContext, _ path: Path, _ fill: Color, line: CGFloat = WorldArt.line) {
        context.fill(path, with: .color(fill))
        context.stroke(path, with: .color(ink), style: StrokeStyle(lineWidth: line, lineCap: .round, lineJoin: .round))
    }

    static func stroke(_ context: GraphicsContext, _ path: Path, _ color: Color, line: CGFloat) {
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: line, lineCap: .round, lineJoin: .round))
    }

    // MARK: The window

    /// The blind of the window, `shade` of the way down: slats of cream
    /// and a wooden rail.
    static func blind(_ context: GraphicsContext, shade: Double) {
        guard shade > 0.01 else { return }
        let window = RoomPlaces.window
        let tl = point(window.topLeft), tr = point(window.topRight)
        let bl = point(window.bottomLeft), br = point(window.bottomRight)
        let down = CGFloat(min(1, shade))
        let left = lerp(tl, bl, down), right = lerp(tr, br, down)
        toon(context, polygon([tl, tr, right, left]), cream, line: 4)
        var slat: CGFloat = 0.14
        while slat < down - 0.04 {
            var path = Path()
            path.move(to: lerp(tl, bl, slat))
            path.addLine(to: lerp(tr, br, slat))
            stroke(context, path, ink.opacity(0.35), line: 2)
            slat += 0.14
        }
        var rail = Path()
        rail.move(to: left)
        rail.addLine(to: right)
        stroke(context, rail, ink, line: 7)
        stroke(context, rail, wood, line: 3)
    }

    // MARK: The ladder and the loft

    /// The ladder from the floor of the room to the hatch of the loft.
    static func ladder(_ context: GraphicsContext) {
        let base = point(RoomPlaces.ladderBase), top = point(RoomPlaces.ladderTop)
        let half = CGFloat(RoomPlaces.ladderWidth) / 2
        var rung = base.y - 22
        while rung > top.y + 10 {
            var path = Path()
            path.move(to: CGPoint(x: base.x - half, y: rung))
            path.addLine(to: CGPoint(x: base.x + half, y: rung))
            stroke(context, path, ink, line: 8)
            stroke(context, path, wood, line: 4)
            rung -= 30
        }
        for x in [base.x - half, base.x + half] {
            var rail = Path()
            rail.move(to: CGPoint(x: x, y: base.y))
            rail.addLine(to: CGPoint(x: x, y: top.y))
            stroke(context, rail, ink, line: 10)
            stroke(context, rail, woodDark, line: 5)
        }
    }

    /// The loft, in the square over the room (y from -512 to 0): a small
    /// attic with a round window, a floor of planks with the hatch of the
    /// ladder, and the shelf of notebooks. The newest notebook is
    /// `slide` of its way onto the shelf.
    static func loft(_ context: GraphicsContext, tint: RoomTint, notebooks: Int, slide: Double) {
        var context = context
        context.translateBy(x: 0, y: -CGFloat(RoomPlaces.size))
        // The attic: two walls under a roof.
        let attic = polygon([CGPoint(x: 256, y: 70), CGPoint(x: 462, y: 196), CGPoint(x: 462, y: 392),
                             CGPoint(x: 50, y: 392), CGPoint(x: 50, y: 196)])
        toon(context, attic, RoomPalette.shade(tint, 1.0), line: 6)
        var roof = Path()
        roof.move(to: CGPoint(x: 30, y: 208))
        roof.addLine(to: CGPoint(x: 256, y: 70))
        roof.addLine(to: CGPoint(x: 482, y: 208))
        stroke(context, roof, ink, line: 14)
        stroke(context, roof, WorldArt.roof, line: 8)
        // The round window.
        toon(context, Path(ellipseIn: CGRect(x: 232, y: 132, width: 48, height: 48)), glass, line: 5)
        // The floor, with the hatch where the ladder comes up.
        toon(context, Path(roundedRect: CGRect(x: 44, y: 380, width: 424, height: 26), cornerRadius: 6), wood, line: 5)
        let hatch = CGFloat(RoomPlaces.ladderBase.x)
        context.fill(Path(roundedRect: CGRect(x: hatch - 30, y: 383, width: 60, height: 20), cornerRadius: 4),
                     with: .color(ink.opacity(0.75)))
        // The shelf.
        let shelf = CGRect(x: 78, y: 300, width: 132, height: 9)
        let count = min(max(0, notebooks), shelfRoom)
        for index in 0..<count {
            let newest = index == count - 1
            let part = newest ? CGFloat(min(1, max(0, slide))) : 1
            let x = shelf.minX + 8 + CGFloat(index) * 17 + (1 - part) * 44
            let height: CGFloat = index % 3 == 1 ? 34 : 40
            var book = context
            book.opacity = Double(part)
            toon(book, Path(roundedRect: CGRect(x: x, y: shelf.minY - height, width: 13, height: height), cornerRadius: 2),
                 WorldArt.notebooks[index % WorldArt.notebooks.count], line: 3)
        }
        toon(context, Path(roundedRect: shelf, cornerRadius: 3), woodDark, line: 4)
    }

    // MARK: The request

    /// The amber card in the hand of the character. `origin` is the top
    /// left of the character box, `size` its side.
    static func card(_ context: GraphicsContext, origin: CGPoint, size: CGFloat, amount: Double) {
        guard amount > 0.01 else { return }
        var context = context
        context.opacity = min(1, amount)
        context.translateBy(x: origin.x + size * 0.27, y: origin.y + size * 0.60)
        context.rotate(by: .degrees(-10))
        let scale = CGFloat(0.8 + 0.2 * min(1, amount))
        context.scaleBy(x: scale, y: scale)
        let width = size * 0.115, height = size * 0.15
        let rect = CGRect(x: -width / 2, y: -height / 2, width: width, height: height)
        toon(context, Path(roundedRect: rect, cornerRadius: width * 0.18), amber, line: 4)
        let rows: [CGFloat] = [0.34, 0.56]
        for row in rows {
            var text = Path()
            text.move(to: CGPoint(x: rect.minX + width * 0.24, y: rect.minY + height * row))
            text.addLine(to: CGPoint(x: rect.maxX - width * 0.24, y: rect.minY + height * row))
            stroke(context, text, ink.opacity(0.7), line: 2.5)
        }
    }

    /// The ring around the "!" bubble of the wait loop: an amber arc for
    /// the part of the time that is left, on a faint track.
    static func ring(_ context: GraphicsContext, origin: CGPoint, size: CGFloat, left: Double) {
        let center = CGPoint(x: origin.x + size * 0.762, y: origin.y + size * 0.255)
        let radius = size * 0.165
        let track = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius))
        stroke(context, track, ink.opacity(0.16), line: 5)
        let part = min(1, max(0, left))
        guard part > 0.002 else { return }
        var arc = Path()
        arc.addArc(center: center, radius: radius, startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * part),
                   clockwise: false)
        stroke(context, arc, ink, line: 8)
        stroke(context, arc, amber, line: 4.5)
    }

    // MARK: The mailbox

    /// The mailbox on its post, with the flag `flag` of the way up and
    /// the box `hop` of a hop over the ground.
    static func mailbox(_ context: GraphicsContext, flag: Double, hop: Double) {
        let foot = point(RoomPlaces.mailbox)
        let lift = CGFloat(RoomPlaces.hopHeight * hop)
        // The shadow shrinks while the box is in the air.
        let shadow = 20 - 6 * CGFloat(hop)
        context.fill(Path(ellipseIn: CGRect(x: foot.x - shadow, y: foot.y - 4, width: 2 * shadow, height: 8)),
                     with: .color(ink.opacity(0.16)))
        var lifted = context
        lifted.translateBy(x: 0, y: -lift)
        toon(lifted, Path(roundedRect: CGRect(x: foot.x - 4, y: foot.y - 38, width: 8, height: 38), cornerRadius: 2),
             woodDark, line: 4)
        let body = CGRect(x: foot.x - 27, y: foot.y - 70, width: 54, height: 34)
        // The flag: an arm on the side of the box, down along it or up.
        let pivot = CGPoint(x: body.maxX - 6, y: body.maxY - 8)
        var arm = lifted
        arm.translateBy(x: pivot.x, y: pivot.y)
        arm.rotate(by: .degrees(-90 * flag))
        var pole = Path()
        pole.move(to: .zero)
        pole.addLine(to: CGPoint(x: 26, y: 0))
        stroke(arm, pole, ink, line: 6)
        toon(arm, Path(roundedRect: CGRect(x: 16, y: -13, width: 15, height: 11), cornerRadius: 2), WorldArt.flag, line: 3.5)
        var box = Path()
        box.move(to: CGPoint(x: body.minX, y: body.maxY))
        box.addLine(to: CGPoint(x: body.minX, y: body.minY + 16))
        box.addQuadCurve(to: CGPoint(x: body.minX + 16, y: body.minY), control: CGPoint(x: body.minX, y: body.minY))
        box.addLine(to: CGPoint(x: body.maxX - 16, y: body.minY))
        box.addQuadCurve(to: CGPoint(x: body.maxX, y: body.minY + 16), control: CGPoint(x: body.maxX, y: body.minY))
        box.addLine(to: CGPoint(x: body.maxX, y: body.maxY))
        box.closeSubpath()
        toon(lifted, box, WorldArt.box)
        var slot = Path()
        slot.move(to: CGPoint(x: body.minX + 12, y: body.minY + 15))
        slot.addLine(to: CGPoint(x: body.maxX - 20, y: body.minY + 15))
        stroke(lifted, slot, ink, line: 4)
    }

    // MARK: The copy

    /// A small house: walls, a roof and a door. `center` is the middle
    /// of its base, `width` the width of its walls.
    static func house(_ context: GraphicsContext, base: CGPoint, width: CGFloat, line: CGFloat) {
        let height = width * 0.56
        let walls = CGRect(x: base.x - width / 2, y: base.y - height, width: width, height: height)
        toon(context, Path(roundedRect: walls, cornerRadius: width * 0.05), paper, line: line)
        context.fill(Path(roundedRect: CGRect(x: base.x - width * 0.09, y: base.y - height * 0.6, width: width * 0.18,
                                              height: height * 0.6), cornerRadius: width * 0.03),
                     with: .color(ink.opacity(0.8)))
        let roofTop = CGPoint(x: base.x, y: walls.minY - width * 0.42)
        toon(context, polygon([CGPoint(x: walls.minX - width * 0.12, y: walls.minY + 1), roofTop,
                               CGPoint(x: walls.maxX + width * 0.12, y: walls.minY + 1)]), roof, line: line)
    }

    /// The model on the desk with its glow, the house it stands for, and
    /// the parts of an apply on their way from one to the other.
    static func copy(_ context: GraphicsContext, glow: Double, breath: Double, apply: Double?) {
        // The house shows while changes wait and while the parts fly; it
        // goes when the last part has landed.
        let shown = apply.map { $0 < 0.85 ? 1 : (1 - $0) / 0.15 } ?? glow
        guard shown > 0.01 || glow > 0.01 else { return }
        let model = point(RoomPlaces.model), home = point(RoomPlaces.house)
        if glow > 0.01 {
            let radius: CGFloat = 40
            let halo = Path(ellipseIn: CGRect(x: model.x - radius, y: model.y - 13 - radius, width: 2 * radius, height: 2 * radius))
            context.fill(halo, with: .radialGradient(Gradient(colors: [amber.opacity(0.85 * glow * breath), amber.opacity(0)]),
                                                     center: CGPoint(x: model.x, y: model.y - 13), startRadius: 4,
                                                     endRadius: radius))
        }
        var parts = context
        parts.opacity = max(shown, glow)
        house(parts, base: model, width: 24, line: 3)
        var far = context
        far.opacity = shown
        house(far, base: CGPoint(x: home.x, y: home.y + 22), width: 46, line: 5)
        guard let apply else { return }
        let from = RoomPoint(x: RoomPlaces.model.x, y: RoomPlaces.model.y - 14)
        for index in 0..<3 {
            let part = (apply - Double(index) * 0.14) / 0.72
            guard part > 0, part < 1 else { continue }
            let place = point(RoomPlaces.arc(from, RoomPlaces.house, part, height: 46))
            var block = context
            block.opacity = min(1, 6 * part, 6 * (1 - part))
            toon(block, Path(roundedRect: CGRect(x: place.x - 6, y: place.y - 6, width: 12, height: 12), cornerRadius: 3),
                 amber, line: 3)
        }
    }

    // MARK: Spawn

    /// The child room at the end of its path: the dots of the path come
    /// first, then the floor, then the two walls rise. An envelope comes
    /// back along the path when the child ends.
    static func child(_ context: GraphicsContext, build: Double, envelope: Double?, tint: RoomTint) {
        guard build > 0.01 || envelope != nil else { return }
        let c = point(RoomPlaces.child), start = point(RoomPlaces.pathStart)
        let end = CGPoint(x: c.x - 40, y: c.y + 10)
        var dim = context
        dim.opacity = min(1, build * 4)
        let dots = 7
        for index in 0..<dots {
            let part = CGFloat(index) / CGFloat(dots - 1)
            guard build >= Double(part) * 0.3 else { continue }
            let dot = lerp(start, end, part)
            dim.fill(Path(ellipseIn: CGRect(x: dot.x - 3, y: dot.y - 3, width: 6, height: 6)), with: .color(ink.opacity(0.55)))
        }
        func stage(_ from: Double, _ to: Double) -> CGFloat {
            CGFloat(min(1, max(0, (build - from) / (to - from))))
        }
        let floor = stage(0.15, 0.45), left = stage(0.4, 0.75), right = stage(0.65, 1)
        let top = CGPoint(x: c.x, y: c.y - 14), east = CGPoint(x: c.x + 32, y: c.y + 2)
        let south = CGPoint(x: c.x, y: c.y + 18), west = CGPoint(x: c.x - 32, y: c.y + 2)
        if floor > 0 {
            var slab = context
            slab.opacity = Double(floor)
            let middle = CGPoint(x: c.x, y: c.y + 2)
            toon(slab, polygon([top, east, south, west].map { lerp(middle, $0, 0.6 + 0.4 * floor) }),
                 RoomPalette.shade(tint, 0.84), line: 4)
        }
        let wall: CGFloat = 34
        if left > 0 {
            toon(context, polygon([west, top, CGPoint(x: top.x, y: top.y - wall * left), CGPoint(x: west.x, y: west.y - wall * left)]),
                 RoomPalette.shade(tint, 0.98), line: 4)
        }
        if right > 0 {
            toon(context, polygon([top, east, CGPoint(x: east.x, y: east.y - wall * right), CGPoint(x: top.x, y: top.y - wall * right)]),
                 RoomPalette.shade(tint, 0.91), line: 4)
        }
        guard let envelope else { return }
        let place = point(RoomPlaces.arc(RoomPoint(x: end.x, y: end.y), RoomPlaces.pathStart, envelope, height: 16))
        var letter = context
        letter.opacity = min(1, 8 * envelope, 5 * (1 - envelope))
        WorldArt.envelope(letter, center: place, width: 26)
    }

    static func envelope(_ context: GraphicsContext, center: CGPoint, width: CGFloat) {
        let height = width * 0.68
        let rect = CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
        toon(context, Path(roundedRect: rect, cornerRadius: 2.5), paper, line: 3.5)
        var flap = Path()
        flap.move(to: CGPoint(x: rect.minX + 1, y: rect.minY + 1))
        flap.addLine(to: CGPoint(x: rect.midX, y: rect.midY + 1))
        flap.addLine(to: CGPoint(x: rect.maxX - 1, y: rect.minY + 1))
        stroke(context, flap, ink, line: 2.5)
    }

    // MARK: Frost

    /// Frost that grows from the four corners of the room square: a pale
    /// sheet with a crystal edge. At 1 the sheets meet along the edges and
    /// leave the middle of the room clear.
    static func frost(_ context: GraphicsContext, amount: Double) {
        guard amount > 0.01 else { return }
        let size = CGFloat(RoomPlaces.size)
        context.fill(Path(CGRect(x: 0, y: 0, width: size, height: size)), with: .color(ice.opacity(0.16 * amount)))
        let reach = size * 0.60 * CGFloat(amount)
        let corners: [(CGPoint, Double)] = [(CGPoint(x: 0, y: 0), 0), (CGPoint(x: size, y: 0), 90),
                                            (CGPoint(x: size, y: size), 180), (CGPoint(x: 0, y: size), 270)]
        for (corner, turn) in corners {
            var path = Path()
            path.move(to: corner)
            let spikes = 10
            for index in 0...spikes {
                let angle = (turn + 90 * Double(index) / Double(spikes)) * Double.pi / 180
                // Long and short crystals in turn; the same every frame.
                let length = reach * (index % 2 == 0 ? 1 : 0.76) * (index % 3 == 0 ? 0.92 : 1)
                path.addLine(to: CGPoint(x: corner.x + CGFloat(cos(angle)) * length, y: corner.y + CGFloat(sin(angle)) * length))
            }
            path.closeSubpath()
            context.fill(path, with: .color(ice.opacity(0.66)))
            stroke(context, path, Color.white.opacity(0.95), line: 4)
            stroke(context, path, ink.opacity(0.18), line: 1.5)
        }
    }
}

// MARK: - The canvases

/// The parts behind the character: the loft, the ladder and the blind.
/// With a loft the canvas is two squares high: the loft over the room.
@MainActor
struct WorldBackCanvas: View {
    let frame: RoomMotionFrame
    let tint: RoomTint

    /// True when the frame has a part for this canvas.
    static func draws(_ frame: RoomMotionFrame) -> Bool {
        frame.hasLoft || frame.shade > 0.01
    }

    var body: some View {
        Canvas { context, size in
            let unit = size.width / CGFloat(RoomPlaces.size)
            context.scaleBy(x: unit, y: unit)
            if frame.hasLoft {
                context.translateBy(x: 0, y: CGFloat(RoomPlaces.size))
                WorldArt.loft(context, tint: tint, notebooks: frame.notebooks, slide: frame.notebookSlide)
                WorldArt.ladder(context)
            }
            WorldArt.blind(context, shade: frame.shade)
        }
        .accessibilityHidden(true)
    }
}

/// The parts in front of the character: the copy, the mailbox, the child
/// room, the amber card and the ring.
@MainActor
struct WorldFrontCanvas: View {
    let frame: RoomMotionFrame
    let tint: RoomTint
    /// The top left of the character box where the character is now, and
    /// the side of the box, in room pixels.
    let character: CGPoint
    let characterSize: CGFloat
    /// The breath of the glow at this moment.
    let breath: Double

    static func draws(_ frame: RoomMotionFrame) -> Bool {
        frame.mailbox || frame.card > 0.01 || frame.ring != nil || frame.glow > 0.01 || frame.apply != nil
            || frame.build > 0.01 || frame.envelope != nil
    }

    var body: some View {
        Canvas { context, size in
            let unit = size.width / CGFloat(RoomPlaces.size)
            context.scaleBy(x: unit, y: unit)
            WorldArt.copy(context, glow: frame.glow, breath: breath, apply: frame.apply)
            if frame.mailbox { WorldArt.mailbox(context, flag: frame.flag, hop: frame.hop) }
            WorldArt.child(context, build: frame.build, envelope: frame.envelope, tint: tint)
            if let left = frame.ring { WorldArt.ring(context, origin: character, size: characterSize, left: left) }
            WorldArt.card(context, origin: character, size: characterSize, amount: frame.card)
        }
        .accessibilityHidden(true)
    }
}

/// The frost over a room.
@MainActor
struct FrostCanvas: View {
    let amount: Double

    var body: some View {
        Canvas { context, size in
            let unit = size.width / CGFloat(RoomPlaces.size)
            context.scaleBy(x: unit, y: unit)
            WorldArt.frost(context, amount: amount)
        }
        .accessibilityHidden(true)
    }
}
