import Foundation

// The rules that keep the Rooms view smooth and readable, without AppKit:
// the scenes of all rooms in one pass, the shared tick of the sprite
// loops, the work the loops cost on a display, and the color of the stage
// behind a room in each appearance.

/// The rooms of the library in sidebar order, built in one pass over the
/// apps and one pass over the questions. A card reads its entry; it does
/// not group the apps or count the questions again.
public struct RoomBoard: Equatable, Sendable {
    public struct Entry: Equatable, Sendable, Identifiable {
        public var app: AppItem
        public var scene: RoomScene
        /// The open questions of the app.
        public var questions: Int

        public var id: String { app.key }

        public init(app: AppItem, scene: RoomScene, questions: Int) {
            self.app = app
            self.scene = scene
            self.questions = questions
        }
    }

    public var entries: [Entry]

    public init(entries: [Entry]) {
        self.entries = entries
    }

    /// The instance keys in room order.
    public var keys: [String] { entries.map(\.id) }

    /// The apps in sidebar order: instances after their first one.
    public static func order(_ apps: [AppItem]) -> [AppItem] {
        InstanceGroup.groups(apps).flatMap(\.items)
    }

    /// The open questions of each app, by profile name.
    public static func questionCounts(_ questions: [QuestionJSON]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for question in questions { counts[question.app, default: 0] += 1 }
        return counts
    }

    /// The scene of each app is the single-app rule, with the character
    /// color of `CharacterColor.spread`: rooms next to each other differ.
    public static func of(_ apps: [AppItem], questions: [QuestionJSON]) -> RoomBoard {
        let counts = questionCounts(questions)
        let ordered = order(apps)
        let colors = CharacterColor.spread(ordered.map(\.name))
        let entries = ordered.enumerated().map { index, app -> Entry in
            let count = counts[app.name] ?? 0
            var scene = RoomScene.of(app, index: index, questions: count)
            if let color = colors[app.name] { scene.color = color }
            return Entry(app: app, scene: scene, questions: count)
        }
        return RoomBoard(entries: entries)
    }
}

extension CharacterColor {
    /// The characters of the apps `names`, in library order. An app takes
    /// the color of its name (`of(app:)`) unless one of the five apps
    /// before it has that color; then it takes the next color in
    /// `appColors` that none of them has. So the first six apps all
    /// differ, and no app has the color of a near neighbor. All instances
    /// of an app share its color.
    public static func spread(_ names: [String]) -> [String: CharacterColor] {
        let all = appColors
        var colors: [String: CharacterColor] = [:]
        var recent: [CharacterColor] = []
        for name in names where colors[name] == nil {
            var color = of(app: name)
            if recent.contains(color), let start = all.firstIndex(of: color) {
                for step in 1..<all.count {
                    let next = all[(start + step) % all.count]
                    if !recent.contains(next) {
                        color = next
                        break
                    }
                }
            }
            colors[name] = color
            recent.append(color)
            if recent.count >= all.count { recent.removeFirst() }
        }
        return colors
    }
}

/// The columns of the rooms grid and the width of a card.
public struct RoomGridFit: Equatable, Sendable {
    public var columns: Int
    public var cardWidth: Double

    public init(columns: Int, cardWidth: Double) {
        self.columns = columns
        self.cardWidth = cardWidth
    }
}

extension RoomGridNavigation {
    /// Fits `cells` cards in `width`: as many columns as fit at
    /// `minCard`, but not more than there are cards; then the cards grow
    /// to fill the row, up to `maxCard`. So a full grid has no ragged
    /// right edge, and a library of two apps has large cards.
    public static func fit(width: Double, cells: Int, minCard: Double, maxCard: Double, spacing: Double) -> RoomGridFit {
        let most = columns(width: width, cardWidth: minCard, spacing: spacing)
        let count = max(1, min(most, max(1, cells)))
        let free = ((width - Double(count - 1) * spacing) / Double(count)).rounded(.down)
        return RoomGridFit(columns: count, cardWidth: min(max(minCard, maxCard), max(minCard, free)))
    }
}

extension RoomScene {
    /// The room of the empty library: the gray character asleep in a
    /// cream room.
    public static let empty = RoomScene(tint: .cream, color: .gray, pose: .sleep)
}

// MARK: - The shared tick

extension SpritePlayer {
    /// The grid all loops tick on. Every loop starts on a multiple of the
    /// frame interval from here, so all rooms change their frame at the
    /// same instants: 8 updates of the window in a second, not 8 for each
    /// room at its own moment.
    public static let epoch = Date(timeIntervalSinceReferenceDate: 0)

    /// `date` moved up to the next tick of the grid; a date on a tick
    /// stays. The interval is 1/8 s, so the ticks are exact in a Double.
    public static func aligned(_ date: Date) -> Date {
        let ticks = (date.timeIntervalSince(epoch) * fps).rounded(.up)
        return epoch.addingTimeInterval(ticks / fps)
    }
}

/// What the sprite loops cost on a display, measured with a fake clock:
/// the display draws `refreshRate` frames a second, and a display frame is
/// busy when at least one room shows a new sprite frame in it.
public struct SpriteFrameWork: Equatable, Sendable {
    /// The sprite frames that changed, over all rooms.
    public var updates: Int
    /// The display frames in which at least one room changed.
    public var busyFrames: Int
    /// The display frames looked at.
    public var frames: Int

    public init(updates: Int, busyFrames: Int, frames: Int) {
        self.updates = updates
        self.busyFrames = busyFrames
        self.frames = frames
    }

    /// Steps a display clock `frames` times from `from` and counts the
    /// changes of `players`.
    public static func measure(_ players: [SpritePlayer], playing: Bool, from: Date, frames: Int,
                               refreshRate: Double = 60) -> SpriteFrameWork {
        var shown = players.map { $0.frame(at: from, playing: playing) }
        var work = SpriteFrameWork(updates: 0, busyFrames: 0, frames: max(0, frames))
        guard frames > 0, refreshRate > 0 else { return work }
        for step in 1...frames {
            let now = from.addingTimeInterval(Double(step) / refreshRate)
            var busy = false
            for (index, player) in players.enumerated() {
                let frame = player.frame(at: now, playing: playing)
                if frame != shown[index] {
                    shown[index] = frame
                    work.updates += 1
                    busy = true
                }
            }
            if busy { work.busyFrames += 1 }
        }
        return work
    }
}

// MARK: - Colors

/// An sRGB color, each part from 0 to 1.
public struct RGB: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(_ red: Double, _ green: Double, _ blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// The relative luminance of WCAG 2.
    public var luminance: Double {
        func linear(_ part: Double) -> Double {
            part <= 0.03928 ? part / 12.92 : pow((part + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// The contrast ratio of WCAG 2 against `other`: 1 to 21.
    public func contrast(_ other: RGB) -> Double {
        let high = max(luminance, other.luminance)
        let low = min(luminance, other.luminance)
        return (high + 0.05) / (low + 0.05)
    }
}

/// The stage: the soft panel behind a room. The art has a transparent
/// background and a dark outline, so on a dark window the outline would be
/// lost. The stage is a pastel of the room tint in the light appearance
/// and a muted mid tone in the dark one, light enough for the outline.
public enum RoomStage {
    /// The outline color of the art.
    public static let ink = RGB(43.0 / 255, 33.0 / 255, 64.0 / 255)

    /// The least contrast of the outline against a dark stage, and
    /// against a dark stage with Increase Contrast.
    public static let darkContrast = 2.4
    public static let darkHighContrast = 3.5

    public static func color(_ tint: RoomTint, dark: Bool, highContrast: Bool) -> RGB {
        switch (dark, highContrast) {
        case (false, _):
            switch tint {
            case .cream: return RGB(0.99, 0.96, 0.89)
            case .blue: return RGB(0.91, 0.95, 1.00)
            case .lilac: return RGB(0.95, 0.92, 1.00)
            case .mint: return RGB(0.91, 0.97, 0.93)
            }
        case (true, false):
            switch tint {
            case .cream: return RGB(0.46, 0.42, 0.34)
            case .blue: return RGB(0.33, 0.40, 0.50)
            case .lilac: return RGB(0.41, 0.37, 0.52)
            case .mint: return RGB(0.32, 0.44, 0.38)
            }
        case (true, true):
            switch tint {
            case .cream: return RGB(0.60, 0.55, 0.45)
            case .blue: return RGB(0.44, 0.53, 0.66)
            case .lilac: return RGB(0.54, 0.49, 0.68)
            case .mint: return RGB(0.43, 0.58, 0.50)
            }
        }
    }
}
