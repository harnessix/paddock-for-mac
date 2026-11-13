#if DEBUG
import AppKit
import PaddockKit
import SwiftUI

/// Debug builds only: one frozen moment of a motion, drawn large for a
/// snapshot (`PADDOCK_LAUNCHER_SNAPSHOT_MOTION=NAME@MS`). The rooms take
/// the frozen moment from the environment. The small room also shows the
/// motions between views: the zoom, a card that comes or goes, the lift
/// under the pointer. The cable is the one of the Plumbing view.
@MainActor
struct MotionGallery: View {
    let freeze: MotionFreeze
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The lines of a debug window; they are not in the catalog.
    static func caption(_ freeze: MotionFreeze) -> String {
        freeze.motion.rawValue + " at " + String(freeze.milliseconds) + " ms"
    }

    static func note(reduceMotion: Bool) -> String {
        reduceMotion ? "Reduce Motion: cross-fade" : "Full motion"
    }

    var body: some View {
        HStack(alignment: .top, spacing: Space.xxl) {
            StagedRoom(scene: RoomScene(tint: .cream, color: .orange, pose: .work),
                       icon: .image(NSApp.applicationIconImage), side: 360)
            VStack(alignment: .leading, spacing: Space.l) {
                Text(verbatim: MotionGallery.caption(freeze))
                    .font(.headline)
                Text(verbatim: MotionGallery.note(reduceMotion: reduceMotion))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                StagedRoom(scene: RoomScene(tint: .blue, color: .teal, pose: .work),
                           icon: .image(NSApp.applicationIconImage), side: RoomSize.card)
                    .modifier(ZoomEffect(progress: freeze.motion == .zoom ? freeze.progress : 1, origin: nil, own: .zero,
                                         reduceMotion: reduceMotion, plain: true))
                    .frozenCardMotion()
                    .hoverLift(false)
                PlumbingCable(device: RoomWorld.Device())
                    .frame(width: 280)
            }
        }
        .padding(Space.xxl)
        .frame(minWidth: 780, minHeight: 440, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.motionFreeze, freeze)
    }
}
#endif
