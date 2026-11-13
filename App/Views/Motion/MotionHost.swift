import PaddockKit
import SwiftUI

// The clock of the motion layer. A host holds the track of one room and
// asks SwiftUI for a new frame only at the ticks of `RoomTicks`: 30 a
// second while a motion runs, 8 a second for the sprite loop, none for a
// room at rest with no loop, and none at all for a room that is off
// screen or in a hidden window.

/// One moment of a room: what to draw and when it is.
struct MotionMoment {
    var snapshot: RoomMotionSnapshot
    var date: Date
    /// The start of the sprite loop on the shared grid.
    var spriteStart: Date
    /// True when the sprite loop plays.
    var playing: Bool
}

/// The ticks of a room as a schedule of a `TimelineView`.
struct RoomSchedule: TimelineSchedule {
    let track: RoomMotionTrack
    let spriteStart: Date
    let motion: RoomMotionMode

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> RoomTicks {
        RoomTicks.of(track, from: startDate, spriteStart: spriteStart, plays: motion == .full, mode: motion)
    }
}

/// Holds the motion of one room: the world and the pose go in, `content`
/// draws the moments. With `entrance` the room comes on screen dark and
/// asleep, then the light turns on and the character wakes.
///
/// With `PADDOCK_LAUNCHER_SNAPSHOT_MOTION` the host draws one frozen
/// moment of a demo and runs no clock.
@MainActor
struct MotionHost<Content: View>: View {
    let world: RoomWorld
    let pose: CharacterPose
    var entrance = false
    @ViewBuilder let content: (MotionMoment) -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.roomWindowVisible) private var windowVisible
    @Environment(\.motionFreeze) private var freeze
    @State private var onScreen = false
    @State private var track: RoomMotionTrack?
    @State private var spriteStart = SpritePlayer.aligned(Date())

    /// The wait before the light of an entrance turns on.
    static var entranceDelay: TimeInterval { 0.35 }

    var body: some View {
        let mode = self.mode(onScreen: onScreen)
        let track = self.track ?? RoomMotionTrack(world: world, pose: pose)
        // A stack and not a group: the host appears once, whichever of
        // its three pictures shows.
        ZStack(alignment: .topLeading) {
            if let freeze, let snapshot = freeze.snapshot(mode: reduceMotion ? .reduced : .full) {
                content(MotionMoment(snapshot: snapshot, date: freeze.date, spriteStart: MotionDemo.start,
                                     playing: !reduceMotion))
            } else if mode == .none {
                let now = Date()
                content(MotionMoment(snapshot: RoomMotionSnapshot(frame: track.frame(at: now)), date: now,
                                     spriteStart: spriteStart, playing: false))
            } else {
                TimelineView(RoomSchedule(track: track, spriteStart: spriteStart, motion: mode)) { context in
                    content(MotionMoment(snapshot: track.snapshot(at: context.date), date: context.date,
                                         spriteStart: spriteStart, playing: mode == .full))
                }
                // A new motion is a new schedule: the ticks start again.
                .id(track.motionEnd)
            }
        }
        .onAppear { appear() }
        .onDisappear {
            onScreen = false
            self.track?.settle()
        }
        .onChange(of: world) { _, _ in update() }
        .onChange(of: pose) { _, _ in update() }
        .onChange(of: mode) { _, new in
            if new == .none { self.track?.settle() }
        }
    }

    private func mode(onScreen: Bool) -> RoomMotionMode {
        RoomMotionMode.of(windowVisible: windowVisible, onScreen: onScreen, reduceMotion: reduceMotion, still: Motion.still)
    }

    private func appear() {
        onScreen = true
        let now = Date()
        spriteStart = SpritePlayer.aligned(now)
        guard entrance, mode(onScreen: true) == .full else {
            track = RoomMotionTrack(world: world, pose: pose)
            return
        }
        var dark = world
        dark.lit = false
        var next = RoomMotionTrack(world: dark, pose: .sleep)
        next.set(world, pose: pose, at: now.addingTimeInterval(MotionHost.entranceDelay), mode: .full)
        track = next
    }

    /// The world or the pose changed: the track goes there in the mode
    /// of now.
    private func update() {
        let now = Date()
        var next = track ?? RoomMotionTrack(world: world, pose: pose)
        let posed = next.pose != pose
        next.set(world, pose: pose, at: now, mode: mode(onScreen: onScreen))
        track = next
        // A new pose starts its loop at the first frame. A frozen
        // character holds a frame of the loop it had.
        if posed, !world.frozen { spriteStart = SpritePlayer.aligned(now) }
    }
}

// MARK: - A frozen moment

/// `PADDOCK_LAUNCHER_SNAPSHOT_MOTION=NAME@MS` of a debug build: every
/// room draws that moment of the motion NAME and no clock runs.
enum MotionFreezeSetting {
    static let variable = "PADDOCK_LAUNCHER_SNAPSHOT_MOTION"

    static let current: MotionFreeze? = {
        #if DEBUG
        return MotionFreeze.parse(ProcessInfo.processInfo.environment[variable])
        #else
        return nil
        #endif
    }()
}

private struct MotionFreezeKey: EnvironmentKey {
    static let defaultValue: MotionFreeze? = MotionFreezeSetting.current
}

extension EnvironmentValues {
    /// The frozen moment the motion layer draws. Nil: the motion runs.
    var motionFreeze: MotionFreeze? {
        get { self[MotionFreezeKey.self] }
        set { self[MotionFreezeKey.self] = newValue }
    }
}
