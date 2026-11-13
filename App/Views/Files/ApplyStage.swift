import PaddockKit
import SwiftUI

// The picture of the Files screen, in the style of the rooms: the copy is
// a small model of the house on the agent's desk, and your folder is the
// house. The model glows while changes wait. An apply moves the changed
// parts from the desk to the house in 700 ms; with Reduce Motion nothing
// moves and a check mark shows on the house. The picture only decorates:
// the line next to it and the toast say the same in words.

/// The colors of the picture. Fixed colors, as the room art has them.
enum StagePalette {
    static let deskTop = Color(red: 0.80, green: 0.62, blue: 0.45)
    static let deskLeft = Color(red: 0.66, green: 0.49, blue: 0.35)
    static let deskRight = Color(red: 0.58, green: 0.42, blue: 0.30)
    static let wall = Color(red: 0.99, green: 0.95, blue: 0.86)
    static let wallShade = Color(red: 0.93, green: 0.87, blue: 0.76)
    static let roof = Color(red: 0.91, green: 0.45, blue: 0.36)
    static let roofShade = Color(red: 0.78, green: 0.36, blue: 0.29)
    static let door = Color(red: 0.55, green: 0.38, blue: 0.28)
    static let window = Color(red: 0.78, green: 0.89, blue: 0.99)
    static let glow = Color(red: 1.0, green: 0.82, blue: 0.30)
    /// The parts that fly: new, changed, deleted, and again.
    static let parts: [Color] = [.green, .orange, roof, window, .green, .orange]
}

private func stagePolygon(_ points: [(Double, Double)]) -> Path {
    Path { path in
        path.addLines(points.map { CGPoint(x: $0.0, y: $0.1) })
        path.closeSubpath()
    }
}

/// A small house, drawn in a 64 point square: the front, the side, the
/// roof, a door and a window.
@MainActor
struct ToonHouse: View {
    var body: some View {
        Canvas { context, size in
            context.scaleBy(x: size.width / 64, y: size.height / 64)
            // The side wall, then the front.
            context.fill(stagePolygon([(40, 30), (56, 24), (56, 46), (40, 54)]), with: .color(StagePalette.wallShade))
            context.fill(stagePolygon([(10, 30), (40, 30), (40, 54), (10, 54)]), with: .color(StagePalette.wall))
            // The roof: the side face, then the gable.
            context.fill(stagePolygon([(25, 10), (45, 6), (59, 23), (43, 31)]), with: .color(StagePalette.roofShade))
            context.fill(stagePolygon([(6, 31), (25, 10), (44, 31)]), with: .color(StagePalette.roof))
            context.fill(Path(roundedRect: CGRect(x: 21, y: 39, width: 9, height: 15), cornerRadius: 1.5),
                         with: .color(StagePalette.door))
            context.fill(Path(roundedRect: CGRect(x: 14, y: 35, width: 5, height: 6), cornerRadius: 1),
                         with: .color(StagePalette.window))
            context.fill(Path(roundedRect: CGRect(x: 32, y: 35, width: 5, height: 6), cornerRadius: 1),
                         with: .color(StagePalette.window))
        }
        .accessibilityHidden(true)
    }
}

/// The agent's desk with the model of the house on it. The model glows
/// while changes wait; the glow pulses only while the window is visible
/// and Reduce Motion is off.
@MainActor
struct DeskModel: View {
    let glows: Bool
    var size: CGFloat = 56
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.roomWindowVisible) private var windowVisible

    var body: some View {
        ZStack {
            Canvas { context, canvas in
                context.scaleBy(x: canvas.width / 64, y: canvas.height / 64)
                context.fill(stagePolygon([(6, 42), (32, 31), (58, 42), (32, 53)]), with: .color(StagePalette.deskTop))
                context.fill(stagePolygon([(6, 42), (32, 53), (32, 60), (6, 49)]), with: .color(StagePalette.deskLeft))
                context.fill(stagePolygon([(32, 53), (58, 42), (58, 49), (32, 60)]), with: .color(StagePalette.deskRight))
            }
            if glows {
                Image(systemName: "circle.fill")
                    .font(.system(size: size * 0.52))
                    .foregroundStyle(StagePalette.glow)
                    .blur(radius: size * 0.09)
                    .symbolEffect(.pulse, isActive: !reduceMotion && !Motion.still && windowVisible)
                    .offset(y: -size * 0.12)
                    .transition(.opacity)
            }
            ToonHouse()
                .frame(width: size * 0.5, height: size * 0.5)
                .offset(y: -size * 0.14)
        }
        .frame(width: size, height: size)
        .animation(Motion.change(reduceMotion), value: glows)
        .accessibilityHidden(true)
    }
}

/// A part on its way from the desk to the house: along an arc, getting
/// smaller. It shows only while it flies.
private struct ArcFlight: ViewModifier, Animatable {
    var progress: Double
    let from: CGPoint
    let to: CGPoint
    let lift: CGFloat

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let t = CGFloat(progress)
        let x = from.x + (to.x - from.x) * t
        let y = from.y + (to.y - from.y) * t - lift * 4 * t * (1 - t)
        return content
            .scaleEffect(1 - 0.35 * t)
            .opacity(progress <= 0.001 || progress >= 0.999 ? 0 : 1)
            .position(x: x, y: y)
    }
}

/// The desk with the model, the way to the house, and the house.
@MainActor
struct ApplyStage: View {
    let counts: CopyCounts?
    /// The last apply that worked: its motion plays once.
    let flight: ApplyFlight?
    var tint: RoomTint = .cream
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var parts = 0
    @State private var flying = false
    @State private var checked = false
    @State private var landed = false
    @State private var sequence: Task<Void, Never>?

    static let tile: CGFloat = 56
    static let gap: CGFloat = 40
    static var width: CGFloat { tile * 2 + gap }

    /// The check mark grows in; with no motion it is just there.
    private var checkTransition: AnyTransition {
        if reduceMotion || Motion.still { return .identity }
        return .scale.combined(with: .opacity)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                DeskModel(glows: ApplyMotion.glows(counts), size: ApplyStage.tile * 0.86)
                    .frame(width: ApplyStage.tile, height: ApplyStage.tile)
                    .background(tileShape.fill(RoomStage.fill(tint, scheme: colorScheme, contrast: contrast)))
                way
                ToonHouse()
                    .frame(width: ApplyStage.tile * 0.8, height: ApplyStage.tile * 0.8)
                    .scaleEffect(landed ? 1.07 : 1)
                    .frame(width: ApplyStage.tile, height: ApplyStage.tile)
                    .background(tileShape.fill(RoomStage.fill(.mint, scheme: colorScheme, contrast: contrast)))
                    .overlay(alignment: .bottomTrailing) {
                        if checked {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(Color.white, Color.green)
                                .offset(x: 4, y: 4)
                                .transition(checkTransition)
                                .accessibilityIdentifier("apply-check")
                        }
                    }
            }
            ForEach(0..<parts, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(StagePalette.parts[index % StagePalette.parts.count])
                    .frame(width: 8, height: 8)
                    .modifier(ArcFlight(progress: flying ? 1 : 0,
                                        from: CGPoint(x: ApplyStage.tile * 0.5, y: ApplyStage.tile * 0.36),
                                        to: CGPoint(x: ApplyStage.width - ApplyStage.tile * 0.5, y: ApplyStage.tile * 0.5),
                                        lift: 14 + CGFloat(index % 3) * 4))
                    .animation(flying ? .easeInOut(duration: ApplyMotion.seconds - ApplyMotion.delay(part: index, of: parts))
                        .delay(ApplyMotion.delay(part: index, of: parts)) : nil, value: flying)
            }
        }
        .frame(width: ApplyStage.width, height: ApplyStage.tile, alignment: .topLeading)
        .accessibilityHidden(true)
        .onChange(of: flight?.id) { play() }
        .onDisappear { sequence?.cancel() }
    }

    private var tileShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: ApplyStage.tile * 0.2, style: .continuous)
    }

    /// The way from the desk to the house: three dots and an arrow head.
    private var way: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { _ in
                Circle().fill(Color(nsColor: .tertiaryLabelColor)).frame(width: 3, height: 3)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
        }
        .frame(width: ApplyStage.gap, height: ApplyStage.tile)
    }

    private func play() {
        guard let flight else { return }
        sequence?.cancel()
        let style = ApplyMotion.style(changes: flight.changes, reduceMotion: reduceMotion, still: Motion.still)
        sequence = Task { @MainActor in
            checked = false
            landed = false
            if case .fly(let count) = style {
                // The parts start on the desk, then fly on the next frame.
                flying = false
                parts = count
                try? await Task.sleep(nanoseconds: 30_000_000)
                guard !Task.isCancelled else { return }
                flying = true
                try? await Task.sleep(nanoseconds: UInt64(ApplyMotion.seconds * 1_000_000_000))
                guard !Task.isCancelled else { return }
                flying = false
                parts = 0
                withAnimation(.spring(response: 0.25, dampingFraction: 0.5)) { landed = true }
                withAnimation(.easeOut(duration: Motion.standard)) { checked = true }
            } else {
                // Reduce Motion: the check mark is the whole message.
                checked = true
            }
            try? await Task.sleep(nanoseconds: UInt64(ApplyMotion.checkSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            if case .fly = style {
                withAnimation(.easeOut(duration: Motion.standard)) {
                    checked = false
                    landed = false
                }
            } else {
                checked = false
            }
        }
    }
}
