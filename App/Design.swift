import AppKit
import PaddockKit
import SwiftUI

// The one visual system of the launcher: the spacing steps, the corner
// radii, the motion and the room stage. Views take their numbers from
// here, so the screens agree.

/// The spacing steps, in points. `page` is the margin between the edge of
/// a detail and its content, the same as a grouped form's.
enum Space {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 24
    static let page: CGFloat = xl

    static let all: [CGFloat] = [xs, s, m, l, xl, xxl]
}

/// The corner radii: a card of the rooms grid, a banner in a detail.
enum Radius {
    static let card: CGFloat = 14
    static let banner: CGFloat = 8
}

/// The motion of the launcher: short and eased. With Reduce Motion every
/// animation is nil, so the change shows at once. A UI test run is still
/// too: a check never looks at a view that is half faded in.
enum Motion {
    /// Hover and press feedback.
    static let quick: Double = 0.12
    /// A change of content: a selection, a view that comes in.
    static let standard: Double = 0.18

    /// True in a UI test run (PADDOCK_LAUNCHER_UITEST=1): no motion.
    static let still = ProcessInfo.processInfo.environment["PADDOCK_LAUNCHER_UITEST"] == "1"

    static func hover(_ reduceMotion: Bool, still: Bool = Motion.still) -> Animation? {
        reduceMotion || still ? nil : .easeOut(duration: quick)
    }

    static func change(_ reduceMotion: Bool, still: Bool = Motion.still) -> Animation? {
        reduceMotion || still ? nil : .easeInOut(duration: standard)
    }

    /// A view that comes in fades in; the view it replaces goes at once.
    /// The two never overlap, so no layout holds both and the
    /// accessibility tree never shows a view that already left.
    static var enter: AnyTransition {
        .asymmetric(insertion: .opacity, removal: .identity)
    }

    /// A card that comes in: a fade and a small growth.
    static var cardEnter: AnyTransition {
        .asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.96)), removal: .identity)
    }
}

// MARK: - Quiet shapes

extension View {
    /// A quiet capsule behind a status word. With Increase Contrast the
    /// fill is too faint to show the shape, so the capsule gets an edge.
    func quietCapsule(_ fill: AnyShapeStyle = AnyShapeStyle(.fill.quaternary)) -> some View {
        modifier(QuietCapsule(fill: fill))
    }

    /// A quiet panel behind a notice in a detail, with the same edge
    /// under Increase Contrast.
    func quietPanel() -> some View {
        modifier(QuietPanel())
    }
}

private struct QuietCapsule: ViewModifier {
    let fill: AnyShapeStyle
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .background(fill, in: Capsule())
            .overlay {
                if contrast == .increased {
                    Capsule()
                        .strokeBorder(Color(nsColor: .labelColor), lineWidth: 1)
                        .accessibilityHidden(true)
                }
            }
    }
}

private struct QuietPanel: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .padding(Space.m)
            .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: Radius.banner, style: .continuous))
            .overlay {
                if contrast == .increased {
                    RoundedRectangle(cornerRadius: Radius.banner, style: .continuous)
                        .strokeBorder(Color(nsColor: .labelColor), lineWidth: 1)
                        .accessibilityHidden(true)
                }
            }
    }
}

// MARK: - The room stage

extension RoomStage {
    /// Whether `appearance` is dark.
    ///
    /// An appearance does not say whether it has Increase Contrast. On
    /// macOS 27, `NSAppearance(named: .accessibilityHighContrastDarkAqua)`
    /// has the name `NSAppearanceNameDarkAqua`, and `bestMatch` over the
    /// plain and the high contrast names gives `.darkAqua` for it. So the
    /// contrast never comes from an appearance: a SwiftUI view reads
    /// `colorSchemeContrast` (see `fill`), and AppKit code reads
    /// `increasesContrast`.
    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// Increase Contrast of System Settings, for AppKit code.
    @MainActor static var increasesContrast: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    /// The stage color of `tint` for AppKit with the given contrast: it
    /// follows Dark Mode by itself.
    static func nsColor(_ tint: RoomTint, highContrast: Bool) -> NSColor {
        NSColor(name: nil) { appearance in
            RoomStage.solid(RoomStage.color(tint, dark: RoomStage.isDark(appearance), highContrast: highContrast))
        }
    }

    /// The stage color of `tint` for AppKit, with Increase Contrast as it
    /// is now. It follows Dark Mode by itself. Ask again when
    /// `NSWorkspace.accessibilityDisplayOptionsDidChangeNotification`
    /// comes: the color keeps the contrast it was made with.
    @MainActor
    static func nsColor(_ tint: RoomTint) -> NSColor {
        nsColor(tint, highContrast: increasesContrast)
    }

    /// `rgb` as a fixed sRGB color.
    static func solid(_ rgb: RGB) -> NSColor {
        NSColor(srgbRed: CGFloat(rgb.red), green: CGFloat(rgb.green), blue: CGFloat(rgb.blue), alpha: 1)
    }

    /// The stage color of a SwiftUI view, from the color scheme and the
    /// contrast of its environment. A view does not go through an
    /// appearance: SwiftUI tells it both facts directly.
    static func fill(_ tint: RoomTint, scheme: ColorScheme, contrast: ColorSchemeContrast) -> Color {
        Color(nsColor: solid(color(tint, dark: scheme == .dark, highContrast: contrast == .increased)))
    }

    /// The room against the stage: the room is `roomScale` of the stage
    /// side and sits `topInset` of the side under the top edge. The art
    /// ends above its lower edge, so the room looks centered.
    static let roomScale: CGFloat = 0.9
    static let topInset: CGFloat = 0.1
    static let cornerScale: CGFloat = 0.09

    static func roomSide(stage: CGFloat) -> CGFloat {
        stage * roomScale
    }
}

/// A room on its stage: a soft panel in the tint of the room, `side`
/// points square. The whole view only decorates.
///
/// The room is a `RoomSceneView`: it moves when its state changes. A page
/// that knows more than the scene gives the `world` of the room (a
/// request, the network, a frozen session). `zoom` names the part of the
/// room in the zoom from a card of a grid to the room of a detail.
/// `entrance` lets the room come on screen dark, then the light turns on.
@MainActor
struct StagedRoom: View {
    let scene: RoomScene
    let icon: RoomIcon
    let side: CGFloat
    var world: RoomWorld?
    var zoom: RoomZoom?
    var entrance = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        RoomSceneView(scene: scene, icon: icon, side: RoomStage.roomSide(stage: side), world: world, entrance: entrance)
            .padding(.top, side * RoomStage.topInset)
            .frame(width: side, height: side, alignment: .top)
            .background {
                RoundedRectangle(cornerRadius: side * RoomStage.cornerScale, style: .continuous)
                    .fill(RoomStage.fill(scene.tint, scheme: colorScheme, contrast: contrast))
                    .accessibilityHidden(true)
            }
            .roomZoom(zoom)
            .accessibilityHidden(true)
    }
}
