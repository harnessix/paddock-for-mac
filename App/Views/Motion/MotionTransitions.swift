import PaddockKit
import SwiftUI

// The motion between views: a card that comes into the grid or leaves
// it, the lift of a card under the pointer, and the zoom from a card of
// the grid to the room of the detail. The lengths and the curves are the
// ones of `WorldMotion`.

extension WorldMotion {
    /// The SwiftUI animation of this motion. With Reduce Motion it is the
    /// short cross-fade of every transition. In a UI test run it is nil:
    /// a check never looks at a view that is half way.
    func animation(reduceMotion: Bool, still: Bool = Motion.still) -> Animation? {
        if still { return nil }
        if reduceMotion { return .linear(duration: WorldMotion.reducedFade) }
        switch curve {
        case .linear: return .linear(duration: duration)
        case .easeIn: return .easeIn(duration: duration)
        case .easeOut: return .easeOut(duration: duration)
        case .easeInOut: return .easeInOut(duration: duration)
        case .spring(let bounce): return .spring(duration: duration, bounce: bounce)
        }
    }
}

// MARK: - Cards

/// The scale and the opacity of a card at one end of its transition.
struct CardPhase: ViewModifier {
    let scale: Double
    let opacity: Double

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale)
            .opacity(opacity)
    }
}

extension AnyTransition {
    /// A card of a rooms grid: it comes with a soft growth and a fade
    /// and leaves with a small shrink and a fade. With Reduce Motion the
    /// card only fades. In a UI test run it is `Motion.cardEnter`: the
    /// card that leaves goes at once.
    static func roomCard(reduceMotion: Bool, still: Bool = Motion.still) -> AnyTransition {
        if still { return Motion.cardEnter }
        let rest = CardPhase(scale: 1, opacity: 1)
        let enter = CardMotion.entering(0), leave = CardMotion.leaving(1)
        let insertion = AnyTransition
            .modifier(active: CardPhase(scale: reduceMotion ? 1 : enter.scale, opacity: enter.opacity), identity: rest)
            .animation(WorldMotion.cardEnter.animation(reduceMotion: reduceMotion, still: still))
        let removal = AnyTransition
            .modifier(active: CardPhase(scale: reduceMotion ? 1 : leave.scale, opacity: leave.opacity), identity: rest)
            .animation(WorldMotion.cardLeave.animation(reduceMotion: reduceMotion, still: still))
        return .asymmetric(insertion: insertion, removal: removal)
    }
}

extension View {
    /// Lifts a card a little while the pointer is over it. Put it before
    /// `onHover`: the lift moves the picture, not the place the pointer
    /// is tested against, so a card at the edge of the pointer does not
    /// flicker. With Reduce Motion the card stays where it is.
    func hoverLift(_ hovering: Bool) -> some View {
        modifier(HoverLift(hovering: hovering))
    }

    /// Shows a frozen moment of the card motions of a snapshot
    /// (`card-enter@MS`, `card-leave@MS`); else nothing changes.
    func frozenCardMotion() -> some View {
        modifier(FrozenCardMotion())
    }
}

struct HoverLift: ViewModifier {
    let hovering: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.motionFreeze) private var freeze

    func body(content: Content) -> some View {
        let lift = HoverLift.lift(hovering: hovering, reduceMotion: reduceMotion, freeze: freeze)
        content
            .scaleEffect(lift.scale)
            .offset(y: -lift.lift)
            .animation(WorldMotion.hover.animation(reduceMotion: reduceMotion), value: hovering)
    }

    /// The lift in points and the scale of a card.
    static func lift(hovering: Bool, reduceMotion: Bool, freeze: MotionFreeze?) -> (lift: Double, scale: Double) {
        if reduceMotion { return (0, 1) }
        if let freeze, freeze.motion == .hover { return CardMotion.hover(freeze.progress) }
        return CardMotion.hover(hovering ? 1 : 0)
    }
}

struct FrozenCardMotion: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.motionFreeze) private var freeze

    func body(content: Content) -> some View {
        let phase = FrozenCardMotion.phase(freeze, reduceMotion: reduceMotion)
        content.modifier(phase)
    }

    static func phase(_ freeze: MotionFreeze?, reduceMotion: Bool) -> CardPhase {
        guard let freeze else { return CardPhase(scale: 1, opacity: 1) }
        let progress = reduceMotion
            ? min(1, Double(freeze.milliseconds) / Double(WorldMotion.reducedFadeMilliseconds))
            : freeze.progress
        switch freeze.motion {
        case .cardEnter:
            let look = CardMotion.entering(progress)
            return CardPhase(scale: reduceMotion ? 1 : look.scale, opacity: look.opacity)
        case .cardLeave:
            let look = CardMotion.leaving(progress)
            return CardPhase(scale: reduceMotion ? 1 : look.scale, opacity: look.opacity)
        default:
            return CardPhase(scale: 1, opacity: 1)
        }
    }
}

// MARK: - The zoom from the grid to a room

/// The part a room plays in the zoom: the card of the grid it starts
/// from, or the room of the detail that zooms. Both have the key of the
/// app or of the agent run.
enum RoomZoom: Equatable {
    case source(String)
    case target(String)
}

/// Where the cards of the grids are in their window, so the room of a
/// detail knows where it comes from. Nothing observes this: a card that
/// scrolls writes its frame and no view draws again.
@MainActor
final class RoomZoomCenter {
    static let shared = RoomZoomCenter()

    /// A card that left the screen is the start of a zoom for this long:
    /// the grid goes while the detail comes.
    static let memory: TimeInterval = 1

    private var frames: [String: CGRect] = [:]
    private var gone: [String: Date] = [:]

    func record(_ key: String, frame: CGRect) {
        frames[key] = frame
        gone[key] = nil
    }

    func left(_ key: String, at date: Date = Date()) {
        guard frames[key] != nil else { return }
        gone[key] = date
    }

    /// The frame of the card `key`, when the card is on screen or left
    /// it a moment ago. Nil: the detail did not come from a card, so
    /// nothing zooms.
    func origin(_ key: String, at date: Date = Date()) -> CGRect? {
        guard let frame = frames[key], frame.width > 0, frame.height > 0 else { return nil }
        if let went = gone[key], date.timeIntervalSince(went) > RoomZoomCenter.memory {
            frames[key] = nil
            gone[key] = nil
            return nil
        }
        return frame
    }
}

extension View {
    /// The part of this room in the zoom from the grid to the detail.
    @ViewBuilder func roomZoom(_ zoom: RoomZoom?) -> some View {
        switch zoom {
        case .source(let key)?: modifier(RoomZoomSource(key: key))
        case .target(let key)?: modifier(RoomZoomTarget(key: key))
        case nil: self
        }
    }
}

/// A card of the grid: it tells the center where it is.
struct RoomZoomSource: ViewModifier {
    let key: String

    func body(content: Content) -> some View {
        content.background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { RoomZoomCenter.shared.record(key, frame: proxy.frame(in: .global)) }
                    .onChange(of: proxy.frame(in: .global)) { _, frame in
                        RoomZoomCenter.shared.record(key, frame: frame)
                    }
                    .onDisappear { RoomZoomCenter.shared.left(key) }
            }
            .accessibilityHidden(true)
        }
    }
}

/// The room of a detail: when it comes from a card, it starts at the
/// place and the size of the card and springs to its own (450 ms). With
/// Reduce Motion it fades in. A detail that did not come from a card
/// does not move.
struct RoomZoomTarget: ViewModifier {
    let key: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.motionFreeze) private var freeze
    @State private var progress: Double = 1
    @State private var origin: CGRect?
    @State private var own: CGRect = .zero

    func body(content: Content) -> some View {
        let frozen = freeze.flatMap { $0.motion == .zoom ? $0.progress : nil }
        content
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { own = proxy.frame(in: .global) }
                        .onChange(of: proxy.frame(in: .global)) { _, frame in own = frame }
                }
                .accessibilityHidden(true)
            }
            .modifier(ZoomEffect(progress: frozen ?? progress, origin: origin, own: own, reduceMotion: reduceMotion,
                                 plain: frozen != nil))
            .onAppear {
                guard !Motion.still, freeze == nil, let from = RoomZoomCenter.shared.origin(key) else { return }
                origin = from
                progress = 0
                withAnimation(WorldMotion.zoom.animation(reduceMotion: reduceMotion)) { progress = 1 }
            }
    }
}

/// The picture of a room `progress` into its zoom.
struct ZoomEffect: ViewModifier, Animatable {
    var progress: Double
    let origin: CGRect?
    let own: CGRect
    let reduceMotion: Bool
    /// True for a frozen moment with no card: the room grows in place.
    var plain = false

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let look = ZoomEffect.look(progress: progress, origin: origin, own: own, reduceMotion: reduceMotion, plain: plain)
        content
            .scaleEffect(look.transform.scale)
            .offset(x: look.transform.x, y: look.transform.y)
            .opacity(look.opacity)
    }

    static func look(progress: Double, origin: CGRect?, own: CGRect, reduceMotion: Bool,
                     plain: Bool) -> (transform: ZoomTransform, opacity: Double) {
        // With Reduce Motion: a cross-fade in place.
        if reduceMotion { return (.identity, min(1, max(0, progress))) }
        // The room is solid after the first third of the way.
        let opacity = min(1, max(0, progress * 3))
        guard let origin, own.width > 0 else {
            if plain { return (ZoomTransform.plain(progress: progress), opacity) }
            // A zoom that does not know its own place yet stays hidden
            // for that frame: the room does not flash at its end place.
            return (.identity, origin == nil ? 1 : opacity)
        }
        let from = MotionRect(x: Double(origin.minX), y: Double(origin.minY), width: Double(origin.width),
                              height: Double(origin.height))
        let to = MotionRect(x: Double(own.minX), y: Double(own.minY), width: Double(own.width), height: Double(own.height))
        return (ZoomTransform.of(from: from, to: to, progress: progress), opacity)
    }
}
