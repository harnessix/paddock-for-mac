import PaddockKit
import SwiftUI

// PLACEHOLDER ART: the fallback for a PNG that is missing from the asset
// catalog (Rooms/room-TINT, Rooms/character-COLOR-STATE-N). The loader
// logs each missing image once. The shapes draw in the same pixel space
// (rooms 512) and use the same rooms.json geometry. A room says
// "Placeholder art" on it and has a dashed edge, so nobody takes it for
// the final art.

/// The colors of the placeholder art. The real art brings its own.
enum RoomPalette {
    static func wall(_ tint: RoomTint) -> (red: Double, green: Double, blue: Double) {
        switch tint {
        case .cream: return (0.98, 0.93, 0.82)
        case .blue: return (0.83, 0.90, 0.98)
        case .lilac: return (0.91, 0.86, 0.98)
        case .mint: return (0.84, 0.95, 0.89)
        }
    }

    static func shade(_ tint: RoomTint, _ factor: Double) -> Color {
        let c = wall(tint)
        return Color(red: c.red * factor, green: c.green * factor, blue: c.blue * factor)
    }

    static func character(_ color: CharacterColor) -> Color {
        switch color {
        case .gray: return Color(red: 0.62, green: 0.63, blue: 0.66)
        case .orange: return Color(red: 0.97, green: 0.63, blue: 0.32)
        case .blue: return Color(red: 0.40, green: 0.63, blue: 0.95)
        case .green: return Color(red: 0.42, green: 0.80, blue: 0.54)
        case .pink: return Color(red: 0.95, green: 0.56, blue: 0.71)
        case .purple: return Color(red: 0.66, green: 0.53, blue: 0.93)
        case .teal: return Color(red: 0.31, green: 0.76, blue: 0.75)
        }
    }
}

private func polygon(_ points: [(Double, Double)]) -> Path {
    Path { path in
        path.addLines(points.map { CGPoint(x: $0.0, y: $0.1) })
        path.closeSubpath()
    }
}

/// A placeholder room: two walls with a window, the floor, a desk with a
/// laptop whose screen follows rooms.json, and a plant.
@MainActor
struct PlaceholderRoom: View {
    let tint: RoomTint
    let manifest: RoomsManifest

    var body: some View {
        let screen = manifest.room(tint).screen
        let size = manifest.roomSize
        Canvas { context, canvas in
            context.scaleBy(x: canvas.width / CGFloat(size), y: canvas.height / CGFloat(size))
            // Walls and floor.
            context.fill(polygon([(36, 360), (36, 150), (256, 40), (256, 250)]), with: .color(RoomPalette.shade(tint, 0.97)))
            context.fill(polygon([(256, 250), (256, 40), (476, 150), (476, 360)]), with: .color(RoomPalette.shade(tint, 0.90)))
            context.fill(polygon([(256, 250), (476, 360), (256, 470), (36, 360)]), with: .color(RoomPalette.shade(tint, 0.80)))
            // The window on the left wall.
            let window = polygon([(92, 188), (188, 140), (188, 222), (92, 270)])
            context.fill(window, with: .color(Color(red: 0.78, green: 0.89, blue: 0.99)))
            context.stroke(window, with: .color(Color.white), lineWidth: 7)
            // The desk: the top, then the two faces under it.
            context.fill(polygon([(232, 262), (362, 327), (302, 357), (172, 292)]), with: .color(Color(red: 0.80, green: 0.62, blue: 0.45)))
            context.fill(polygon([(172, 292), (302, 357), (302, 397), (172, 332)]), with: .color(Color(red: 0.66, green: 0.49, blue: 0.35)))
            context.fill(polygon([(302, 357), (362, 327), (362, 367), (302, 397)]), with: .color(Color(red: 0.58, green: 0.42, blue: 0.30)))
            // The laptop: the keyboard, then the lid along the screen.
            let bl = screen.bottomLeft, br = screen.bottomRight
            context.fill(polygon([(bl.x, bl.y), (br.x, br.y), (br.x - 24, br.y + 12), (bl.x - 24, bl.y + 12)]),
                         with: .color(Color(white: 0.78)))
            let lid = polygon(screen.corners.map { ($0.x, $0.y) })
            context.fill(lid, with: .color(Color(white: 0.16)))
            context.stroke(lid, with: .color(Color(white: 0.70)), lineWidth: 6)
            // The plant.
            context.fill(polygon([(398, 372), (442, 372), (436, 414), (404, 414)]), with: .color(Color(red: 0.85, green: 0.48, blue: 0.36)))
            for (x, y, w, h) in [(392.0, 318.0, 30.0, 58.0), (418.0, 312.0, 30.0, 62.0), (404.0, 296.0, 30.0, 58.0)] {
                context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: w, height: h)),
                             with: .color(Color(red: 0.36, green: 0.68, blue: 0.42)))
            }
            // The placeholder mark.
            context.stroke(Path(roundedRect: CGRect(x: 8, y: 8, width: size - 16, height: size - 16), cornerRadius: 24),
                           with: .color(Color(white: 0.45)),
                           style: StrokeStyle(lineWidth: 4, dash: [16, 12]))
            context.draw(Text(UIText("Placeholder art"))
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundStyle(Color(white: 0.30)),
                         at: CGPoint(x: 256, y: 494), anchor: .center)
        }
        .accessibilityHidden(true)
    }
}

/// A placeholder character: a round body with a face. Each pose has four
/// frames: work types and bobs, wait raises a hand, sleep breathes with
/// rising bubbles, idle blinks, blocked shakes with crossed eyes.
@MainActor
struct PlaceholderCharacter: View {
    let color: CharacterColor
    let pose: CharacterPose
    let frame: Int

    var body: some View {
        Canvas { context, canvas in
            context.scaleBy(x: canvas.width / 256, y: canvas.height / 256)
            let step = ((frame % 4) + 4) % 4
            let bob: [Double]
            let sway: [Double]
            switch pose {
            case .work: bob = [0, -4, -6, -4]; sway = [0, 0, 0, 0]
            case .wait: bob = [0, -3, 0, -3]; sway = [0, 0, 0, 0]
            case .sleep: bob = [0, 2, 4, 2]; sway = [0, 0, 0, 0]
            case .idle: bob = [0, -2, 0, -2]; sway = [0, 0, 0, 0]
            case .blocked: bob = [0, 0, 0, 0]; sway = [0, -4, 0, 4]
            }
            let cx = 128 + sway[step]
            let cy = 146 + bob[step]
            let ink = Color(white: 0.15)
            var skin = RoomPalette.character(color)
            if pose == .blocked { skin = Color(red: 0.72, green: 0.66, blue: 0.66) }
            // Shadow, body, shine.
            context.fill(Path(ellipseIn: CGRect(x: 66, y: 214, width: 124, height: 22)), with: .color(Color.black.opacity(0.14)))
            context.fill(Path(ellipseIn: CGRect(x: cx - 78, y: cy - 78, width: 156, height: 156)), with: .color(skin))
            context.fill(Path(ellipseIn: CGRect(x: cx - 50, y: cy - 62, width: 40, height: 26)), with: .color(Color.white.opacity(0.35)))
            // Eyes.
            let eyeY = cy - 8
            switch pose {
            case .sleep:
                for x in [cx - 30, cx + 30] {
                    var lid = Path()
                    lid.move(to: CGPoint(x: x - 12, y: eyeY))
                    lid.addQuadCurve(to: CGPoint(x: x + 12, y: eyeY), control: CGPoint(x: x, y: eyeY + 9))
                    context.stroke(lid, with: .color(ink), lineWidth: 5)
                }
                for n in 0..<3 {
                    let rise = Double((step + n) % 4) * 10
                    let index = Double(n)
                    let r: Double = 6 + index * 3
                    let x: Double = cx + 62 + index * 12
                    let y: Double = cy - 70 - index * 22 - rise
                    context.stroke(Path(ellipseIn: CGRect(x: x, y: y, width: r * 2, height: r * 2)),
                                   with: .color(ink.opacity(0.6)), lineWidth: 3)
                }
            case .blocked:
                for x in [cx - 30, cx + 30] {
                    var cross = Path()
                    cross.move(to: CGPoint(x: x - 10, y: eyeY - 10))
                    cross.addLine(to: CGPoint(x: x + 10, y: eyeY + 10))
                    cross.move(to: CGPoint(x: x + 10, y: eyeY - 10))
                    cross.addLine(to: CGPoint(x: x - 10, y: eyeY + 10))
                    context.stroke(cross, with: .color(ink), lineWidth: 5)
                }
                context.fill(Path(ellipseIn: CGRect(x: cx + 50, y: cy - 96, width: 40, height: 40)), with: .color(Color(red: 0.86, green: 0.22, blue: 0.20)))
                context.fill(Path(CGRect(x: cx + 58, y: cy - 79, width: 24, height: 6)), with: .color(Color.white))
            default:
                let blink = pose == .idle && step == 3
                let look: Double = pose == .work ? 6 : (pose == .wait ? -10 : 0)
                for x in [cx - 30, cx + 30] {
                    if blink {
                        context.fill(Path(CGRect(x: x - 10, y: eyeY + look, width: 20, height: 4)), with: .color(ink))
                    } else {
                        context.fill(Path(ellipseIn: CGRect(x: x - 9, y: eyeY + look - 12, width: 18, height: 24)), with: .color(ink))
                        context.fill(Path(ellipseIn: CGRect(x: x - 4, y: eyeY + look - 9, width: 7, height: 7)), with: .color(Color.white))
                    }
                }
            }
            // Mouth.
            var mouth = Path()
            if pose == .blocked {
                mouth.move(to: CGPoint(x: cx - 14, y: cy + 30))
                mouth.addLine(to: CGPoint(x: cx + 14, y: cy + 30))
            } else {
                mouth.move(to: CGPoint(x: cx - 14, y: cy + 24))
                mouth.addQuadCurve(to: CGPoint(x: cx + 14, y: cy + 24), control: CGPoint(x: cx, y: cy + 36))
            }
            context.stroke(mouth, with: .color(ink), lineWidth: 5)
            // Hands.
            let hand = RoomPalette.character(color)
            switch pose {
            case .work:
                let tap: [Double] = [0, 6, 0, 6]
                context.fill(Path(ellipseIn: CGRect(x: cx + 56, y: cy + 36 + tap[step], width: 30, height: 26)), with: .color(hand))
                context.fill(Path(ellipseIn: CGRect(x: cx + 30, y: cy + 52 + tap[(step + 1) % 4], width: 30, height: 26)), with: .color(hand))
            case .wait:
                let wave: [Double] = [0, -8, -12, -8]
                context.fill(Path(ellipseIn: CGRect(x: cx + 70, y: cy - 92 + wave[step], width: 30, height: 30)), with: .color(hand))
            default:
                break
            }
        }
        .accessibilityHidden(true)
    }
}
