import PaddockKit
import SwiftUI

/// One device cable of the Plumbing view: from the plug of the room on
/// the left to the socket of the device on the right. Each new call
/// sends one spark along the cable (400 ms). At a covered socket the
/// spark stops at the cover, and a card rises for your answer.
///
/// State in, motion out, as a room: give the `device` of now. The cable
/// only decorates; the row next to it names the device and its state.
@MainActor
struct PlumbingCable: View {
    let device: RoomWorld.Device

    static let height: CGFloat = 56

    var body: some View {
        MotionHost(world: RoomWorld(device: device), pose: .idle) { moment in
            ZStack {
                if let previous = moment.snapshot.previous {
                    canvas(previous)
                }
                canvas(moment.snapshot.frame)
                    .opacity(moment.snapshot.previous == nil ? 1 : moment.snapshot.fade)
            }
        }
        .frame(minWidth: 120, maxWidth: .infinity, minHeight: PlumbingCable.height, maxHeight: PlumbingCable.height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func canvas(_ frame: RoomMotionFrame) -> some View {
        Canvas { context, size in
            PlumbingCable.draw(context, size: size, frame: frame)
        }
    }

    /// The point `t` of the cable in a canvas of `size`: a line with a
    /// small sag between the plug and the socket.
    static func point(_ t: Double, size: CGSize) -> CGPoint {
        let y = size.height * 0.66
        let start = CGPoint(x: 30, y: y), end = CGPoint(x: size.width - 44, y: y)
        let control = CGPoint(x: (start.x + end.x) / 2, y: y + 12)
        let u = CGFloat(min(1, max(0, t)))
        let a = (1 - u) * (1 - u), b = 2 * u * (1 - u), c = u * u
        return CGPoint(x: a * start.x + b * control.x + c * end.x, y: a * start.y + b * control.y + c * end.y)
    }

    static func draw(_ context: GraphicsContext, size: CGSize, frame: RoomMotionFrame) {
        let start = point(0, size: size), end = point(1, size: size)
        var cable = Path()
        cable.move(to: start)
        cable.addQuadCurve(to: end, control: CGPoint(x: (start.x + end.x) / 2, y: start.y + 12))
        WorldArt.stroke(context, cable, WorldArt.ink, line: 7)
        WorldArt.stroke(context, cable, Color(red: 0.46, green: 0.48, blue: 0.58), line: 3)

        // The plug of the room.
        WorldArt.toon(context, Path(roundedRect: CGRect(x: 8, y: start.y - 9, width: 24, height: 18), cornerRadius: 5),
                      WorldArt.cream, line: 3.5)

        // The socket of the device.
        let socket = CGRect(x: size.width - 44, y: end.y - 16, width: 32, height: 32)
        WorldArt.toon(context, Path(roundedRect: socket, cornerRadius: 7), WorldArt.paper, line: 3.5)
        for x in [socket.midX - 6, socket.midX + 6] {
            context.fill(Path(ellipseIn: CGRect(x: x - 2.5, y: socket.midY - 2.5, width: 5, height: 5)), with: .color(WorldArt.ink))
        }

        // The spark: a short bright piece of the cable with a round head.
        if let spark = frame.spark {
            let head = point(spark, size: size)
            let tail = cable.trimmedPath(from: CGFloat(max(0, spark - 0.12)), to: CGFloat(max(0.001, spark)))
            WorldArt.stroke(context, tail, WorldArt.amberLight.opacity(0.6), line: 9)
            WorldArt.stroke(context, tail, WorldArt.amber, line: 4)
            WorldArt.toon(context, Path(ellipseIn: CGRect(x: head.x - 6, y: head.y - 6, width: 12, height: 12)),
                          WorldArt.amberLight, line: 3)
        }

        guard frame.covered else { return }
        // The cover over the socket; the spark stops at its edge.
        let edge = point(RoomPlaces.sparkStop, size: size).x + 6
        let cover = CGRect(x: edge, y: socket.minY - 4, width: socket.maxX + 4 - edge, height: socket.height + 8)
        // The card rises from behind the cover.
        if frame.deviceCard > 0.01 {
            let rise = CGFloat(frame.deviceCard)
            var card = context
            card.opacity = Double(min(1, rise * 2))
            let rect = CGRect(x: cover.midX - 11, y: cover.minY + 6 - 26 * rise, width: 22, height: 28)
            WorldArt.toon(card, Path(roundedRect: rect, cornerRadius: 4), WorldArt.amber, line: 3.5)
            var text = Path()
            text.move(to: CGPoint(x: rect.minX + 6, y: rect.minY + 9))
            text.addLine(to: CGPoint(x: rect.maxX - 6, y: rect.minY + 9))
            WorldArt.stroke(card, text, WorldArt.ink.opacity(0.7), line: 2.5)
        }
        WorldArt.toon(context, Path(roundedRect: cover, cornerRadius: 7), WorldArt.cream, line: 3.5)
        var grip = Path()
        grip.move(to: CGPoint(x: cover.midX - 7, y: cover.midY))
        grip.addLine(to: CGPoint(x: cover.midX + 7, y: cover.midY))
        WorldArt.stroke(context, grip, WorldArt.ink.opacity(0.55), line: 3)
    }
}
