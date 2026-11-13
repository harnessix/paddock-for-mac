import AppKit
import os
import PaddockKit
import SwiftUI

/// One frame of a sprite: a PNG of the asset catalog (folder `Rooms`), or
/// a marked placeholder drawn with shapes when the PNG is missing.
/// Views only see this type.
enum SpriteFrame: Equatable {
    case image(NSImage)
    case placeholderCharacter(CharacterColor, CharacterPose, index: Int)
    case placeholderRoom(RoomTint)
    /// No front layer: the placeholder room draws its own desk.
    case placeholderFront

    var isPlaceholder: Bool {
        if case .image = self { return false }
        return true
    }
}

/// The art a room holds while it is on screen.
enum RoomArtKey: Hashable {
    case character(CharacterColor, CharacterPose)
    case room(RoomTint)
    case front
}

/// Loads the room art: `room-TINT`, the front layer `room-front-screen`,
/// the frames `character-COLOR-STATE-1…N` and the data asset `rooms`
/// (rooms.json). A missing room or loop gets its placeholder and one log
/// line; a missing or broken rooms.json gets the placeholder geometry.
///
/// Memory: art loads when a room asks for it and stays while a room on
/// screen holds it (`hold`). When the last room that holds it leaves the
/// screen (`release`), the frames go. The rooms grid holds the art of all
/// its rooms while it shows, so a scroll never loads a PNG twice; the art
/// goes when the grid goes. The catalog images are drawn down
/// to the pixels a room needs (`catalogImage`), and NSImage's name cache
/// is not used, so a released frame is really gone.
@MainActor
final class RoomArtLoader {
    static let shared = RoomArtLoader(lookup: RoomArtLoader.catalogImage,
                                      manifestData: { NSDataAsset(name: SpriteName.manifest)?.data })

    /// The frames of a placeholder loop.
    static let placeholderFrames = 4

    let manifest: RoomsManifest
    /// True when rooms.json came from the asset catalog.
    let manifestFromCatalog: Bool
    private let lookup: (String) -> NSImage?
    private var characters: [String: [SpriteFrame]] = [:]
    private var rooms: [RoomTint: SpriteFrame] = [:]
    private var frontLayer: SpriteFrame?
    private var holders: [RoomArtKey: Int] = [:]
    /// The images already logged as missing: one line each.
    private(set) var loggedMissing: Set<String> = []
    private static let log = Logger(subsystem: "dev.paddock.mac", category: "rooms")

    init(lookup: @escaping (String) -> NSImage?, manifestData: () -> Data?) {
        self.lookup = lookup
        if let data = manifestData(), let manifest = try? RoomsManifest.decode(data) {
            self.manifest = manifest
            manifestFromCatalog = true
        } else {
            manifest = .placeholder
            manifestFromCatalog = false
            missing(SpriteName.manifest)
        }
    }

    /// The frames of one loop, never empty. The frames count from 1 and
    /// end at the first missing number.
    func character(_ color: CharacterColor, _ pose: CharacterPose) -> [SpriteFrame] {
        let key = color.rawValue + "-" + pose.rawValue
        if let cached = characters[key] { return cached }
        var frames: [SpriteFrame] = []
        for number in 1...SpriteName.maxFrames {
            guard let image = lookup(SpriteName.character(color, pose, frame: number)) else { break }
            frames.append(.image(image))
        }
        if frames.isEmpty {
            missing(SpriteName.character(color, pose, frame: 1))
            frames = (0..<RoomArtLoader.placeholderFrames).map { .placeholderCharacter(color, pose, index: $0) }
        }
        characters[key] = frames
        return frames
    }

    func room(_ tint: RoomTint) -> SpriteFrame {
        if let cached = rooms[tint] { return cached }
        let frame: SpriteFrame
        if let image = lookup(SpriteName.room(tint)) {
            frame = .image(image)
        } else {
            missing(SpriteName.room(tint))
            frame = .placeholderRoom(tint)
        }
        rooms[tint] = frame
        return frame
    }

    /// The desk and the laptop, drawn over the character.
    func front() -> SpriteFrame {
        if let frontLayer { return frontLayer }
        let frame: SpriteFrame
        if let image = lookup(SpriteName.front) {
            frame = .image(image)
        } else {
            missing(SpriteName.front)
            frame = .placeholderFront
        }
        frontLayer = frame
        return frame
    }

    // MARK: Holding art while on screen

    /// The art of a room scene: its room, its loop and the front layer.
    static func keys(_ scene: RoomScene) -> [RoomArtKey] {
        [.room(scene.tint), .character(scene.color, scene.pose.roomSprite), .front]
    }

    /// The art of several rooms: each key once, in the order of the rooms.
    static func keys(_ scenes: [RoomScene]) -> [RoomArtKey] {
        var seen: Set<RoomArtKey> = []
        var all: [RoomArtKey] = []
        for scene in scenes {
            for key in keys(scene) where seen.insert(key).inserted { all.append(key) }
        }
        return all
    }

    /// Loads the art of `key` now, so the first room that draws it does
    /// not wait for the PNGs.
    func load(_ key: RoomArtKey) {
        switch key {
        case .character(let color, let pose): _ = character(color, pose)
        case .room(let tint): _ = room(tint)
        case .front: _ = front()
        }
    }

    /// A room on screen holds its art: it stays loaded until released.
    func hold(_ keys: [RoomArtKey]) {
        for key in keys { holders[key, default: 0] += 1 }
    }

    /// A room left the screen or changed its art. Art no room holds any
    /// more is dropped; the next room that asks loads it again.
    func release(_ keys: [RoomArtKey]) {
        for key in keys {
            guard let count = holders[key] else { continue }
            if count > 1 {
                holders[key] = count - 1
            } else {
                holders[key] = nil
                drop(key)
            }
        }
    }

    /// True while `key` is loaded.
    func isLoaded(_ key: RoomArtKey) -> Bool {
        switch key {
        case .character(let color, let pose): return characters[color.rawValue + "-" + pose.rawValue] != nil
        case .room(let tint): return rooms[tint] != nil
        case .front: return frontLayer != nil
        }
    }

    /// How many rooms hold `key`.
    func holderCount(_ key: RoomArtKey) -> Int {
        holders[key] ?? 0
    }

    private func drop(_ key: RoomArtKey) {
        switch key {
        case .character(let color, let pose): characters[color.rawValue + "-" + pose.rawValue] = nil
        case .room(let tint): rooms[tint] = nil
        case .front: frontLayer = nil
        }
    }

    private func missing(_ name: String) {
        guard loggedMissing.insert(name).inserted else { return }
        RoomArtLoader.log.error("Room art \(name, privacy: .public) is missing from the asset catalog; drawing a placeholder")
    }

    // MARK: The asset catalog

    /// The pixels a character frame keeps: the largest card draws the
    /// character at about 118 pt, 236 px on a Retina screen. The PNGs are
    /// 512 px.
    static let characterPixels = 256
    /// The pixels a room or the front layer keeps: all 512 of the PNG. A
    /// card of a small library draws its room at up to 230 pt, 460 px on
    /// a Retina screen.
    static let roomPixels = 512

    /// An image of the asset catalog, drawn down to the pixels a room
    /// needs. Not `NSImage(named:)` alone: its cache would keep every
    /// frame for the life of the app.
    nonisolated static func catalogImage(_ name: String) -> NSImage? {
        guard let source = Bundle.main.image(forResource: name) ?? NSImage(named: name) else { return nil }
        let pixels = name.hasPrefix("character-") ? characterPixels : roomPixels
        return downsampled(source, pixels: pixels) ?? source
    }

    /// `image` drawn into a square bitmap of `pixels`, with the point
    /// size of the original.
    nonisolated static func downsampled(_ image: NSImage, pixels: Int) -> NSImage? {
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        guard cgImage.width > pixels || cgImage.height > pixels else {
            return NSImage(cgImage: cgImage, size: image.size)
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        guard let small = context.makeImage() else { return nil }
        return NSImage(cgImage: small, size: image.size)
    }
}

/// The order of the rooms: the order of the sidebar, instances after
/// their first one. The tint of a room comes from its place here.
enum LibraryOrder {
    static func items(_ apps: [AppItem]) -> [AppItem] {
        InstanceGroup.groups(apps).flatMap(\.items)
    }

    static func index(of key: String, in apps: [AppItem]) -> Int {
        items(apps).firstIndex { $0.key == key } ?? 0
    }
}

extension LauncherStore {
    /// The open questions of an app, for the badge of its room.
    func questionCount(_ app: AppItem) -> Int {
        questions.filter { $0.app == app.name }.count
    }

    /// The room of an app, as its card and its detail header show it:
    /// its entry on the board, so the header has the character of the card.
    func roomScene(_ app: AppItem) -> RoomScene {
        RoomBoard.of(apps, questions: questions).entries.first { $0.id == app.key }?.scene
            ?? RoomScene.of(app, index: LibraryOrder.index(of: app.key, in: apps), questions: questionCount(app))
    }
}

/// The spoken line of a room card: the line of the sidebar row, then the
/// questions: `Sample Notes, Running, 3 windows, 2 questions`.
enum RoomSpeech {
    static func of(_ app: AppItem, _ presentation: StatusPresentation, questions: Int) -> String {
        var line = RowSpeech.of(app.title, presentation)
        if questions > 0 { line += ", " + RoomCopy.questions(questions).localized }
        return line
    }
}

/// The room sizes: a library card, the detail header and the onboarding;
/// and the card around a room.
enum RoomSize {
    static let card: CGFloat = 176
    static let header: CGFloat = 160
    static let welcome: CGFloat = 128
    static let cardPadding: CGFloat = 12
    /// The least width of a card; a card grows to `maxCardWidth` when the
    /// library has few apps or the row has room.
    static let cardWidth: CGFloat = card + 2 * cardPadding
    static let maxCardWidth: CGFloat = 280
}
