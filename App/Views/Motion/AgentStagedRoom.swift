import PaddockKit
import SwiftUI

/// The room of an agent run on its stage, with the world of the run: its
/// oldest request at the door, its network at the window, the glow of
/// its changed files and the child rooms of the runs it spawned.
@MainActor
struct AgentStagedRoom: View {
    let room: AgentRoom
    /// The place of the room in its grid: the tint.
    let index: Int
    let side: CGFloat
    var zoom: RoomZoom?
    @Environment(AgentStore.self) private var agents

    var body: some View {
        StagedRoom(scene: room.scene(index: index), icon: .image(AgentScreen.image(room.color)), side: side,
                   world: RoomWorld.of(room, children: AgentRooms.children(of: room, in: agents.rooms)), zoom: zoom)
    }
}
