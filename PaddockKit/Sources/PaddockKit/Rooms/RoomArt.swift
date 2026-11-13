import Foundation

// The rooms of the library: each app is a small isometric room with a
// round character. The art only decorates: every state also has its word,
// its pill and its spoken line. This file holds the rules, so they test
// without AppKit: which sprite shows which state, the sprite clock, the
// laptop screen of rooms.json, and the arrow keys of the grid.

/// What the character does. Each pose is one sprite loop.
public enum CharacterPose: String, CaseIterable, Equatable, Sendable {
    /// Running with a window: types on the laptop.
    case work
    /// A network question waits: looks up with the count as a badge.
    case wait
    /// Stopped, ready or suspended: asleep at the desk.
    case sleep
    /// Starting or stopping, or running with no window yet: awake.
    case idle
    /// Error or blocked.
    case blocked

    /// The loop a room draws for this pose: its own. The `work` loop
    /// brings a laptop of its own; the room hides it behind the desk and
    /// cuts the part that would show under the desk (`CharacterArt.workFloor`).
    public var roomSprite: CharacterPose {
        self
    }

    /// The frames of each loop in the art: 8, or 4 for sleep and blocked.
    public var frameCount: Int {
        switch self {
        case .work, .wait, .idle: return 8
        case .sleep, .blocked: return 4
        }
    }
}

/// The color of a room's walls and floor. Cards take them in this order.
public enum RoomTint: String, CaseIterable, Equatable, Sendable {
    case cream, blue, lilac, mint

    /// The tint of the card at `index`: cream, blue, lilac, mint, cream…
    public static func at(_ index: Int) -> RoomTint {
        let all = RoomTint.allCases
        return all[((index % all.count) + all.count) % all.count]
    }
}

/// The color of a character: the seven colors of the art. Gray is the
/// onboarding character; apps get one of the others.
public enum CharacterColor: String, CaseIterable, Equatable, Sendable {
    case gray, orange, blue, purple, green, pink, teal

    /// The colors an app can get, in a fixed order.
    public static let appColors: [CharacterColor] = [.orange, .blue, .purple, .green, .pink, .teal]

    /// The character of an app: from the profile name, so all instances
    /// of one app share it and it stays the same when the list changes.
    /// FNV-1a, not `hashValue`, which changes at each launch.
    public static func of(app name: String) -> CharacterColor {
        var hash: UInt32 = 2_166_136_261
        for byte in name.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return appColors[Int(hash % UInt32(appColors.count))]
    }
}

/// Everything a room shows apart from the app icon: tint, character,
/// pose, the question badge and the start progress.
public struct RoomScene: Equatable, Sendable {
    public var tint: RoomTint
    public var color: CharacterColor
    public var pose: CharacterPose
    /// The question count on the character, only in the `wait` pose.
    public var badge: Int?
    /// True while the app starts or stops: the room shows a spinner.
    public var showsProgress: Bool

    public init(tint: RoomTint, color: CharacterColor, pose: CharacterPose, badge: Int? = nil,
                showsProgress: Bool = false) {
        self.tint = tint
        self.color = color
        self.pose = pose
        self.badge = badge
        self.showsProgress = showsProgress
    }

    /// The pose of a state. A failure wins over everything, then an open
    /// question, then the state itself.
    public static func pose(_ state: AppState, questions: Int) -> CharacterPose {
        switch state {
        case .error, .blocked: return .blocked
        default: break
        }
        if questions > 0 { return .wait }
        switch state {
        case .running(_, let windows): return windows > 0 ? .work : .idle
        case .starting, .stopping: return .idle
        case .stopped, .saved, .suspended, .error, .blocked: return .sleep
        }
    }

    /// The room of the app at `index` in the library order, with
    /// `questions` open questions.
    public static func of(_ app: AppItem, index: Int, questions: Int) -> RoomScene {
        let pose = RoomScene.pose(app.state, questions: questions)
        let progress: Bool
        switch app.state {
        case .starting, .stopping: progress = true
        default: progress = false
        }
        return RoomScene(tint: .at(index), color: .of(app: app.name), pose: pose,
                         badge: pose == .wait ? questions : nil, showsProgress: progress)
    }

    /// The onboarding room: the gray character at work in a cream room.
    public static let welcome = RoomScene(tint: .cream, color: .gray, pose: .work)
}

/// The names of the sprite images in the asset catalog (folder `Rooms`).
public enum SpriteName {
    /// The most frames a loop can have; the loader stops looking there.
    public static let maxFrames = 32

    /// `character-blue-work-1`: frames count from 1 (the art's files
    /// count from 0: `character-blue-work-0.png` is image set
    /// `character-blue-work-1`). 512×512 px in the @2x slot.
    public static func character(_ color: CharacterColor, _ pose: CharacterPose, frame: Int) -> String {
        "character-\(color.rawValue)-\(pose.rawValue)-\(frame)"
    }

    /// `room-cream`: 512×512 px.
    public static func room(_ tint: RoomTint) -> String {
        "room-\(tint.rawValue)"
    }

    /// The front layer: the desk and the laptop with its screen to the
    /// viewer, drawn over the character. It covers the desk of every
    /// room, so each tint shows the app icon on the laptop screen.
    public static let front = "room-front-screen"

    /// The data asset with the room geometry.
    public static let manifest = "rooms"

    /// Every image the rooms can ask the asset catalog for: the rooms,
    /// the front layer and every frame of every loop a room draws.
    public static var roomImages: [String] {
        var names = RoomTint.allCases.map(room) + [front]
        for color in CharacterColor.allCases {
            for pose in CharacterPose.roomSprites {
                names += (1...pose.frameCount).map { character(color, pose, frame: $0) }
            }
        }
        return names
    }
}

extension CharacterPose {
    /// The loops a room draws: every pose.
    public static var roomSprites: [CharacterPose] {
        var seen: [CharacterPose] = []
        for pose in allCases where !seen.contains(pose.roomSprite) { seen.append(pose.roomSprite) }
        return seen
    }
}

/// The layers of a room, back to front. The art's draw order is room,
/// character, front layer: the character sits behind the desk and the
/// laptop. The app icon lies on the laptop screen of the front layer, the
/// question badge and the start progress on top of all.
public enum RoomLayer: String, CaseIterable, Equatable, Sendable {
    case room, character, front, icon, badge, progress

    /// The order a room draws its layers in.
    public static let drawOrder: [RoomLayer] = [.room, .character, .front, .icon, .badge, .progress]
}

/// The sprite clock: 8 frames a second while the loop plays, else the
/// first frame. A loop plays only while its window is visible, the room
/// is on screen and Reduce Motion is off.
public struct SpritePlayer: Equatable, Sendable {
    public static let fps: Double = 8
    public static var frameInterval: TimeInterval { 1 / fps }

    public var frameCount: Int
    public var start: Date

    public init(frameCount: Int, start: Date) {
        self.frameCount = frameCount
        self.start = start
    }

    public static func isPlaying(windowVisible: Bool, onScreen: Bool, reduceMotion: Bool, frameCount: Int) -> Bool {
        windowVisible && onScreen && !reduceMotion && frameCount > 1
    }

    /// The frame index, from 0, at `date`. A loop that does not play
    /// shows frame 0; so does a date before the start.
    public func frame(at date: Date, playing: Bool) -> Int {
        guard playing, frameCount > 1 else { return 0 }
        let elapsed = date.timeIntervalSince(start)
        guard elapsed > 0 else { return 0 }
        // A small epsilon: 0.125 s × 8 is frame 1, not 0.99999.
        let ticks = Int((elapsed * SpritePlayer.fps + 1e-9).rounded(.down))
        return ticks % frameCount
    }
}

// MARK: - rooms.json

/// A point in the pixels of a room image, y down.
public struct RoomPoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public init(from decoder: Decoder) throws {
        var pair = try decoder.unkeyedContainer()
        x = try pair.decode(Double.self)
        y = try pair.decode(Double.self)
    }

    public func encode(to encoder: Encoder) throws {
        var pair = encoder.unkeyedContainer()
        try pair.encode(x)
        try pair.encode(y)
    }

    public func scaled(_ factor: Double) -> RoomPoint {
        RoomPoint(x: x * factor, y: y * factor)
    }
}

/// The four corners of the laptop screen, as the art draws it.
public struct ScreenQuad: Codable, Equatable, Sendable {
    public var topLeft: RoomPoint
    public var topRight: RoomPoint
    public var bottomRight: RoomPoint
    public var bottomLeft: RoomPoint

    enum CodingKeys: String, CodingKey {
        case topLeft = "top_left"
        case topRight = "top_right"
        case bottomRight = "bottom_right"
        case bottomLeft = "bottom_left"
    }

    public init(topLeft: RoomPoint, topRight: RoomPoint, bottomRight: RoomPoint, bottomLeft: RoomPoint) {
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomRight = bottomRight
        self.bottomLeft = bottomLeft
    }

    public var corners: [RoomPoint] { [topLeft, topRight, bottomRight, bottomLeft] }

    public func scaled(_ factor: Double) -> ScreenQuad {
        ScreenQuad(topLeft: topLeft.scaled(factor), topRight: topRight.scaled(factor),
                   bottomRight: bottomRight.scaled(factor), bottomLeft: bottomLeft.scaled(factor))
    }
}

/// Where the character sprite sits in the room, in room pixels.
public struct CharacterBox: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var size: Double

    public init(x: Double, y: Double, size: Double) {
        self.x = x
        self.y = y
        self.size = size
    }
}

/// `rooms.json` in the asset catalog: the size of the room images, the
/// character box and, for each tint, the laptop screen corners.
///
///     {"v": 1, "room_size": 512, "icon_scale": 0.78,
///      "character": {"x": 60, "y": 236, "size": 200},
///      "rooms": {"cream": {"screen": {"top_left": [250, 228], …}}, …}}
public struct RoomsManifest: Codable, Equatable, Sendable {
    public struct Room: Codable, Equatable, Sendable {
        public var screen: ScreenQuad
        /// A room may move its character; else the shared box.
        public var character: CharacterBox?

        public init(screen: ScreenQuad, character: CharacterBox? = nil) {
            self.screen = screen
            self.character = character
        }
    }

    public var v: Int
    public var roomSize: Double
    /// The side of the icon against the shorter screen edge.
    public var iconScale: Double
    public var character: CharacterBox
    public var rooms: [String: Room]

    enum CodingKeys: String, CodingKey {
        case v
        case roomSize = "room_size"
        case iconScale = "icon_scale"
        case character
        case rooms
    }

    public init(v: Int, roomSize: Double, iconScale: Double, character: CharacterBox, rooms: [String: Room]) {
        self.v = v
        self.roomSize = roomSize
        self.iconScale = iconScale
        self.character = character
        self.rooms = rooms
    }

    /// Reads rooms.json: the file of the art export (`size`, rooms by
    /// file name, see `ArtRoomsFile`) or the older launcher format with
    /// `v` 1.
    public static func decode(_ data: Data) throws -> RoomsManifest {
        if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           object["v"] == nil, object["size"] != nil {
            return try ArtRoomsFile.decode(data).manifest()
        }
        let manifest = try JSONDecoder().decode(RoomsManifest.self, from: data)
        guard manifest.v == 1, manifest.roomSize > 0 else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "rooms.json: v 1 and a room size"))
        }
        return manifest
    }

    /// The room of a tint; a tint missing in the file takes the first one
    /// in tint order, then the placeholder geometry.
    public func room(_ tint: RoomTint) -> Room {
        if let room = rooms[tint.rawValue] { return room }
        for other in RoomTint.allCases {
            if let room = rooms[other.rawValue] { return room }
        }
        return RoomsManifest.placeholder.rooms[tint.rawValue]!
    }

    public func characterBox(_ tint: RoomTint) -> CharacterBox {
        room(tint).character ?? character
    }

    /// The geometry of the placeholder art, the same as the rooms.json
    /// in the asset catalog until the real art comes.
    public static let placeholder: RoomsManifest = {
        let screen = ScreenQuad(topLeft: RoomPoint(x: 252, y: 226), topRight: RoomPoint(x: 324, y: 262),
                                bottomRight: RoomPoint(x: 324, y: 318), bottomLeft: RoomPoint(x: 252, y: 282))
        var rooms: [String: Room] = [:]
        for tint in RoomTint.allCases { rooms[tint.rawValue] = Room(screen: screen) }
        return RoomsManifest(v: 1, roomSize: 512, iconScale: 0.78,
                             character: CharacterBox(x: 60, y: 236, size: 200), rooms: rooms)
    }()
}

// MARK: - rooms.json of the art

/// The rooms.json of the art export, as `Sprites/README.txt` describes it:
///
///     {"size": [512, 512],
///      "rooms": {"room-cream.png": {"character": {"spriteScale": 0.512, "feet": [256, 298], "heightPx": 150}},
///                "room-cream-screen.png": {"screen": {"corners": [[224, 248.1], …]},
///                                          "character": {"spriteScale": 0.512, "feet": [191, 295], …}}}}
///
/// The rooms draw the front layer with the laptop screen to the viewer
/// (`SpriteName.front`), so every tint takes the screen and the
/// character place of the room that has a screen.
public struct ArtRoomsFile: Decodable, Equatable, Sendable {
    public struct Character: Decodable, Equatable, Sendable {
        public var spriteScale: Double
        public var feet: RoomPoint
        public var heightPx: Double
    }

    public struct Screen: Decodable, Equatable, Sendable {
        /// Top left, top right, bottom right, bottom left.
        public var corners: [RoomPoint]
    }

    public struct Room: Decodable, Equatable, Sendable {
        public var character: Character?
        public var screen: Screen?
    }

    public var size: [Double]
    public var rooms: [String: Room]
    /// Optional: the side of the icon against the shorter screen edge.
    public var iconScale: Double?

    enum CodingKeys: String, CodingKey {
        case size, rooms
        case iconScale = "icon_scale"
    }

    /// The room with the laptop screen to the viewer.
    public static let screenRoom = "room-cream-screen.png"
    /// The icon side against the shorter screen edge when the file has none.
    /// 1: the icon is as high as the screen, the largest square that
    /// stays on it. The screen of the art is wider than high, so the icon
    /// covers about 0.6 of it.
    public static let defaultIconScale = 1.0

    public static func decode(_ data: Data) throws -> ArtRoomsFile {
        try JSONDecoder().decode(ArtRoomsFile.self, from: data)
    }

    /// The geometry in the launcher's terms: for each tint the screen
    /// and the character box of the screen room.
    public func manifest() throws -> RoomsManifest {
        func fail(_ text: String) -> Error {
            DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "rooms.json: " + text))
        }
        guard size.count == 2, size[0] > 0, size[0] == size[1] else { throw fail("size is not a square") }
        var name: String? = ArtRoomsFile.screenRoom
        if rooms[ArtRoomsFile.screenRoom]?.screen == nil {
            name = rooms.keys.sorted().first { rooms[$0]?.screen != nil }
        }
        guard let name, let room = rooms[name], let screen = room.screen, let character = room.character else {
            throw fail("no room with a screen and a character")
        }
        guard screen.corners.count == 4 else { throw fail("a screen has four corners") }
        guard character.spriteScale > 0, character.heightPx > 0 else { throw fail("character scale and height") }
        let quad = ScreenQuad(topLeft: screen.corners[0], topRight: screen.corners[1],
                              bottomRight: screen.corners[2], bottomLeft: screen.corners[3])
        let box = CharacterArt.box(character)
        var all: [String: RoomsManifest.Room] = [:]
        for tint in RoomTint.allCases {
            all[tint.rawValue] = RoomsManifest.Room(screen: quad, character: box)
        }
        return RoomsManifest(v: 1, roomSize: size[0], iconScale: iconScale ?? ArtRoomsFile.defaultIconScale,
                             character: box, rooms: all)
    }
}

/// The character PNG: 512 px square, the same camera for every frame.
public enum CharacterArt {
    /// The side of a character PNG in pixels.
    public static let side = 512.0
    /// The top of the antenna in a character PNG, in its pixels: the top
    /// of the idle frames (measured on the export; all colors agree).
    public static let top = 135.0
    /// The underside of the desk, as a part of the room side (326 of
    /// 512 px, measured on the export). The laptop of the `work` loop
    /// reaches below it between the desk legs; a room draws the work loop
    /// only above this line.
    public static let workFloor = 326.0 / 512.0

    /// The point of a character PNG that goes on `feet`: the middle of
    /// the PNG, `heightPx` (in room pixels) below the antenna top.
    public static func feet(_ character: ArtRoomsFile.Character) -> RoomPoint {
        RoomPoint(x: side / 2, y: top + character.heightPx / character.spriteScale)
    }

    /// The square of the character PNG in room pixels.
    public static func box(_ character: ArtRoomsFile.Character) -> CharacterBox {
        let anchor = feet(character)
        let scale = character.spriteScale
        return CharacterBox(x: character.feet.x - anchor.x * scale, y: character.feet.y - anchor.y * scale,
                            size: side * scale)
    }
}

// MARK: - Icon placement

/// A projective map of the plane: `x' = (a x + b y + c) / (g x + h y + 1)`,
/// `y' = (d x + e y + f) / (g x + h y + 1)`. The app icon is a square
/// view; this map puts its corners on the laptop screen.
public struct Homography: Equatable, Sendable {
    public var a, b, c, d, e, f, g, h: Double

    public init(a: Double, b: Double, c: Double, d: Double, e: Double, f: Double, g: Double, h: Double) {
        self.a = a; self.b = b; self.c = c
        self.d = d; self.e = e; self.f = f
        self.g = g; self.h = h
    }

    /// The map of the unit square onto `quad`: (0,0) to the top left,
    /// (1,0) top right, (1,1) bottom right, (0,1) bottom left. Heckbert's
    /// square-to-quad; a parallelogram gives an affine map (g = h = 0).
    public static func unitSquare(to quad: ScreenQuad) -> Homography {
        let x0 = quad.topLeft.x, y0 = quad.topLeft.y
        let x1 = quad.topRight.x, y1 = quad.topRight.y
        let x2 = quad.bottomRight.x, y2 = quad.bottomRight.y
        let x3 = quad.bottomLeft.x, y3 = quad.bottomLeft.y
        let sx = x0 - x1 + x2 - x3
        let sy = y0 - y1 + y2 - y3
        var g = 0.0, h = 0.0
        if abs(sx) > 1e-12 || abs(sy) > 1e-12 {
            let dx1 = x1 - x2, dx2 = x3 - x2, dy1 = y1 - y2, dy2 = y3 - y2
            let det = dx1 * dy2 - dx2 * dy1
            if abs(det) > 1e-12 {
                g = (sx * dy2 - dx2 * sy) / det
                h = (dx1 * sy - sx * dy1) / det
            }
        }
        return Homography(a: x1 - x0 + g * x1, b: x3 - x0 + h * x3, c: x0,
                          d: y1 - y0 + g * y1, e: y3 - y0 + h * y3, f: y0,
                          g: g, h: h)
    }

    public func apply(_ p: RoomPoint) -> RoomPoint {
        let w = g * p.x + h * p.y + 1
        return RoomPoint(x: (a * p.x + b * p.y + c) / w, y: (d * p.x + e * p.y + f) / w)
    }

    /// The same map for a source of `width` × `height` in place of the
    /// unit square: the matrix of a view of that size.
    public func fromSize(width: Double, height: Double) -> Homography {
        Homography(a: a / width, b: b / height, c: c, d: d / width, e: e / height, f: f,
                   g: g / width, h: h / height)
    }
}

/// Where the app icon goes on the laptop screen of a room drawn at
/// `side` points.
public enum IconPlacement {
    /// The icon's own quad: a centered square on the screen, its side
    /// `iconScale` of the shorter screen edge, in the screen's own plane.
    public static func iconQuad(_ manifest: RoomsManifest, tint: RoomTint, side: Double) -> ScreenQuad {
        let factor = side / manifest.roomSize
        let screen = manifest.room(tint).screen.scaled(factor)
        let map = Homography.unitSquare(to: screen)
        let top = distance(screen.topLeft, screen.topRight)
        let left = distance(screen.topLeft, screen.bottomLeft)
        guard top > 0, left > 0 else { return screen }
        let edge = manifest.iconScale * min(top, left)
        let du = min(1, edge / top) / 2
        let dv = min(1, edge / left) / 2
        return ScreenQuad(topLeft: map.apply(RoomPoint(x: 0.5 - du, y: 0.5 - dv)),
                          topRight: map.apply(RoomPoint(x: 0.5 + du, y: 0.5 - dv)),
                          bottomRight: map.apply(RoomPoint(x: 0.5 + du, y: 0.5 + dv)),
                          bottomLeft: map.apply(RoomPoint(x: 0.5 - du, y: 0.5 + dv)))
    }

    /// The map of an icon view `iconSide` points square, laid at the top
    /// left of the room view, onto its place on the screen.
    public static func transform(_ manifest: RoomsManifest, tint: RoomTint, side: Double, iconSide: Double) -> Homography {
        Homography.unitSquare(to: iconQuad(manifest, tint: tint, side: side))
            .fromSize(width: iconSide, height: iconSide)
    }

    /// The character box in points for a room `side` points wide.
    public static func characterBox(_ manifest: RoomsManifest, tint: RoomTint, side: Double) -> CharacterBox {
        let box = manifest.characterBox(tint)
        let factor = side / manifest.roomSize
        return CharacterBox(x: box.x * factor, y: box.y * factor, size: box.size * factor)
    }

    static func distance(_ p: RoomPoint, _ q: RoomPoint) -> Double {
        ((p.x - q.x) * (p.x - q.x) + (p.y - q.y) * (p.y - q.y)).squareRoot()
    }
}

// MARK: - Grid keys

/// The arrow keys of the rooms grid, as Finder's icon view moves.
public enum RoomGridNavigation {
    public enum Move: Equatable, Sendable {
        case left, right, up, down
    }

    /// How many cards of `cardWidth` fit in `width` with `spacing`
    /// between them; at least one.
    public static func columns(width: Double, cardWidth: Double, spacing: Double) -> Int {
        guard cardWidth > 0 else { return 1 }
        return max(1, Int(((width + spacing) / (cardWidth + spacing)).rounded(.down)))
    }

    /// The card after a key, from `index` (nil: no card selected yet). The
    /// selection stops at the edges; Down into a shorter last row goes to
    /// the last card.
    public static func move(_ index: Int?, _ move: Move, count: Int, columns: Int) -> Int? {
        guard count > 0 else { return nil }
        let columns = max(1, columns)
        guard let index, index >= 0, index < count else { return 0 }
        switch move {
        case .left: return max(0, index - 1)
        case .right: return min(count - 1, index + 1)
        case .up: return index - columns >= 0 ? index - columns : index
        case .down:
            if index + columns < count { return index + columns }
            let lastRow = (count - 1) / columns
            return index / columns < lastRow ? count - 1 : index
        }
    }
}

/// The texts of the rooms.
public enum RoomCopy {
    /// The question badge, spoken after the state.
    public static func questions(_ count: Int) -> UIText {
        count == 1 ? UIText("1 question") : UIText("%lld questions", count)
    }
}
