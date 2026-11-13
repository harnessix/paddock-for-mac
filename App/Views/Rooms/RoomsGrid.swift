import AppKit
import PaddockKit
import SwiftUI

/// How the library shows its apps in the detail: the detail of the
/// selected app (List), or a grid of rooms (Rooms). The choice is kept.
enum LibraryLayout: String, CaseIterable, Equatable {
    case list, rooms
}

/// The List / Rooms switch of the toolbar. It shows on the pages that
/// have rooms (`ToolbarRule.showsLayoutSwitch`).
@MainActor
struct LibraryLayoutPicker: View {
    @Environment(UIRouter.self) private var router

    var body: some View {
        Picker(selection: Binding(get: { router.libraryLayout }, set: { router.setLibraryLayout($0) })) {
            // Words, not two bare symbols: a segment says what it shows.
            Text("List").tag(LibraryLayout.list)
            Text("Rooms").tag(LibraryLayout.rooms)
        } label: {
            Text("View")
        }
        .pickerStyle(.segmented)
        .fixedSize()
        .help(Text("Show the apps as a list or as rooms"))
        .accessibilityIdentifier("library-layout")
    }
}

/// The Rooms view: the grid, and the detail of a room on top of it after
/// Return or a double click. The sidebar selection is the grid selection.
@MainActor
struct LibraryRoomsView: View {
    @Environment(LauncherStore.self) private var store
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            RoomsGrid(open: open)
                .navigationDestination(for: String.self) { key in
                    if store.app(named: key) != nil {
                        AppDetailView(name: key)
                            .id(key)
                    } else {
                        EmptyAppsView()
                    }
                }
        }
        // A sidebar click while a detail shows: the detail of that app.
        .onChange(of: store.selection) { _, selection in
            guard let shown = path.last else { return }
            if case .app(let key)? = selection, key != shown { path = [key] }
        }
        // An app that was just added, or that a notice points to: its
        // detail opens, not only its card in the grid.
        .onChange(of: store.openRoom, initial: true) { _, room in
            guard case .app(let key)? = room, store.app(named: key) != nil else { return }
            path = [key]
            store.openRoom = nil
        }
    }

    private func open(_ key: String) {
        store.selection = .app(key)
        path = [key]
    }
}

/// The rooms of all apps in sidebar order. The arrow keys move the
/// selection, Return opens the detail.
///
/// The grid builds the scenes of all rooms once for each update
/// (`RoomBoard`) and holds their art while it shows, so a card that
/// scrolls back in draws from memory. The width comes from the layout
/// pass itself: the first frame already has its columns.
///
/// The cards fill the row (`RoomGridNavigation.fit`): a library of two
/// apps has large cards, a full one has no ragged right edge, and a grid
/// narrower than the window sits in its middle. The last card is the
/// add-app room.
@MainActor
struct RoomsGrid: View {
    let open: (String) -> Void
    @Environment(LauncherStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState
    @FocusState private var focused: Bool
    /// The art the grid holds for its rooms.
    @State private var held: [RoomArtKey] = []

    static let spacing: CGFloat = Space.l
    static let margin: CGFloat = Space.page

    var body: some View {
        let board = RoomBoard.of(store.apps, questions: store.questions)
        let keys = board.keys
        let addScene = AddRoomCard.scene(after: keys.count)
        let art = RoomArtLoader.keys(board.entries.map(\.scene) + [addScene])
        // The selection is strong only while the grid has the keys.
        let emphasized = focused && controlActiveState == .key
        GeometryReader { geometry in
            let fit = RoomGridNavigation.fit(width: Double(geometry.size.width - 2 * RoomsGrid.margin),
                                             cells: keys.count + 1,
                                             minCard: Double(RoomSize.cardWidth),
                                             maxCard: Double(RoomSize.maxCardWidth),
                                             spacing: Double(RoomsGrid.spacing))
            let columns = fit.columns
            let cardWidth = CGFloat(fit.cardWidth)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(cardWidth), spacing: RoomsGrid.spacing,
                                                                 alignment: .top),
                                             count: columns),
                              alignment: .leading,
                              spacing: RoomsGrid.spacing) {
                        ForEach(board.entries) { entry in
                            RoomCard(entry: entry,
                                     width: cardWidth,
                                     selected: selectedKey == entry.id,
                                     emphasized: emphasized,
                                     select: {
                                         store.selection = .app(entry.id)
                                         focused = true
                                     },
                                     open: { open(entry.id) })
                                .id(entry.id)
                                .transition(.roomCard(reduceMotion: reduceMotion))
                        }
                        AddRoomCard(scene: addScene, width: cardWidth)
                    }
                    .padding(RoomsGrid.margin)
                    .frame(maxWidth: .infinity, alignment: .top)
                    // A room that comes or goes: the others move to their
                    // new places, they do not jump.
                    .animation(Motion.change(reduceMotion), value: keys)
                }
                .focusable()
                .focused($focused)
                .focusEffectDisabled()
                .onKeyPress(.leftArrow) { move(.left, keys: keys, columns: columns) }
                .onKeyPress(.rightArrow) { move(.right, keys: keys, columns: columns) }
                .onKeyPress(.upArrow) { move(.up, keys: keys, columns: columns) }
                .onKeyPress(.downArrow) { move(.down, keys: keys, columns: columns) }
                .onKeyPress(.return) {
                    guard let key = selectedKey, keys.contains(key) else { return .ignored }
                    open(key)
                    return .handled
                }
                .onChange(of: selectedKey) { _, key in
                    guard let key else { return }
                    withAnimation(Motion.change(reduceMotion)) { proxy.scrollTo(key) }
                }
                .onAppear {
                    focused = true
                    if let key = selectedKey { proxy.scrollTo(key) }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Rooms"))
        .accessibilityIdentifier("rooms-grid")
        .onAppear { hold(art) }
        .onDisappear { hold([]) }
        .onChange(of: art) { _, new in hold(new) }
        .task(id: art) { await warm(art) }
    }

    private var selectedKey: String? {
        if case .app(let key)? = store.selection { return key }
        return nil
    }

    private func move(_ move: RoomGridNavigation.Move, keys: [String], columns: Int) -> KeyPress.Result {
        let index = selectedKey.flatMap { keys.firstIndex(of: $0) }
        guard let next = RoomGridNavigation.move(index, move, count: keys.count, columns: columns) else { return .ignored }
        store.selection = .app(keys[next])
        return .handled
    }

    /// Holds `keys` in place of the art held before.
    private func hold(_ keys: [RoomArtKey]) {
        guard keys != held else { return }
        let art = RoomArtLoader.shared
        art.hold(keys)
        art.release(held)
        held = keys
    }

    /// Loads the art of the rooms below the window edge, one loop at a
    /// time with a pause between them, so the first scroll does not wait
    /// for PNGs. The task ends when the grid goes or its art changes.
    private func warm(_ keys: [RoomArtKey]) async {
        let art = RoomArtLoader.shared
        for key in keys where !art.isLoaded(key) {
            try? await Task.sleep(nanoseconds: RoomsGrid.warmPause)
            if Task.isCancelled { return }
            art.load(key)
        }
    }

    /// The pause between two loops of `warm`: two display frames.
    static let warmPause: UInt64 = 33_000_000
}

/// One room card: the room on its stage, the app name, the state pill and
/// the primary session button. The room, name and state are one element
/// for VoiceOver; the button stays a button of its own.
///
/// The card answers the pointer (a lift under it) and shows the selection
/// with an accent ring and a wash; the ring is gray while another pane or
/// window has the keys, as a Finder selection is.
@MainActor
struct RoomCard: View {
    let entry: RoomBoard.Entry
    /// The width of the card; the stage takes it less the padding.
    let width: CGFloat
    let selected: Bool
    /// True while the grid has the keyboard focus in the key window.
    let emphasized: Bool
    let select: () -> Void
    let open: () -> Void
    @Environment(LauncherStore.self) private var store
    @Environment(UIRouter.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var hovering = false

    static let corner: CGFloat = Radius.card

    private var app: AppItem { entry.app }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let presentation = StatusPresentation.of(app.state, now: context.date)
            VStack(spacing: Space.s) {
                VStack(spacing: Space.s) {
                    StagedRoom(scene: entry.scene, icon: .app(path: app.json.bundlePath),
                               side: RoomCardLook.stageSide(cardWidth: width),
                               world: RoomWorld.of(app, questions: entry.questions), zoom: .source(app.key))
                    VStack(spacing: Space.xs) {
                        // The icon again at a size that reads: the one on
                        // the laptop screen is a few points wide.
                        HStack(spacing: Space.xs) {
                            AppIcon(path: app.json.bundlePath, size: RoomCardLook.nameIcon)
                            Text(verbatim: app.title)
                                .font(.headline)
                                .labelInk()
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        StatusPill(presentation: presentation)
                    }
                }
                .contentShape(Rectangle())
                // The single click selects at once: it does not wait to
                // see whether a second click follows.
                .gesture(TapGesture(count: 2).onEnded { open() })
                .simultaneousGesture(TapGesture().onEnded { select() })
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: RoomSpeech.of(app, presentation, questions: entry.questions)))
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                .accessibilityAction { open() }
                .accessibilityIdentifier("room-card-" + app.key)
                primaryButton
            }
            .padding(RoomSize.cardPadding)
            .frame(width: width)
            .background { cardBackground }
            .overlay {
                RoundedRectangle(cornerRadius: RoomCard.corner, style: .continuous)
                    .strokeBorder(RoomCardLook.ring(selected: selected, emphasized: emphasized),
                                  lineWidth: RoomCardLook.ringWidth(selected: selected, emphasized: emphasized,
                                                                    increasedContrast: contrast == .increased))
                    .accessibilityHidden(true)
            }
            .hoverLift(hovering)
            .onHover { hovering = $0 }
            .onDisappear { hovering = false }
            .animation(Motion.hover(reduceMotion), value: hovering)
            .animation(Motion.hover(reduceMotion), value: selected)
            .animation(Motion.hover(reduceMotion), value: emphasized)
            .contextMenu { AppRowMenu(app: app) }
        }
    }

    /// The card surface, a wash of the accent color when selected, a
    /// light veil under the pointer, and a soft shadow that grows with it.
    private var cardBackground: some View {
        let shape = RoundedRectangle(cornerRadius: RoomCard.corner, style: .continuous)
        return shape
            .fill(Color(nsColor: .controlBackgroundColor))
            .shadow(color: Color.black.opacity(RoomCardLook.shadowOpacity(hovering: hovering)),
                    radius: RoomCardLook.shadowRadius(hovering: hovering), x: 0, y: hovering ? 2 : 1)
            .overlay {
                shape.fill(Color.accentColor.opacity(RoomCardLook.washOpacity(selected: selected, emphasized: emphasized)))
            }
            .overlay {
                shape.fill(Color(nsColor: .labelColor).opacity(RoomCardLook.veilOpacity(hovering: hovering)))
            }
            .accessibilityHidden(true)
    }

    /// Start, Resume or Open; nothing while the app starts, stops or is
    /// blocked. The height stays, so the cards line up. The button of the
    /// selected card is the prominent one: one accent button in the grid.
    @ViewBuilder private var primaryButton: some View {
        let buttons = SessionButtons.of(app.state, canSuspend: store.capabilities.suspend)
        if let primary = SessionButtons.primary(of: buttons) {
            Button(SessionMenuTitle.of(primary)) {
                SessionCommand.perform(primary, app, store: store, router: router)
            }
            .modifier(SessionButtonStyle(primary: selected))
            .controlSize(.regular)
            .disabled(primary == .start && !store.binary.isUsable)
            .accessibilityHint(Text(verbatim: app.title))
            .accessibilityIdentifier("room-primary-" + app.key)
        } else {
            Button("Start") {}
                .buttonStyle(.bordered)
                .hidden()
                .accessibilityHidden(true)
        }
    }
}

/// The last card of the grid: an empty room with the gray character
/// awake and a plus. A click opens the Add App sheet. It has the size and
/// the lines of an app card, with a dashed edge.
@MainActor
struct AddRoomCard: View {
    let scene: RoomScene
    let width: CGFloat
    @Environment(LauncherStore.self) private var store
    @Environment(UIRouter.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    /// The room after `count` app rooms: the next tint, the gray character.
    static func scene(after count: Int) -> RoomScene {
        RoomScene(tint: .at(count), color: .gray, pose: .idle)
    }

    var body: some View {
        let side = RoomCardLook.stageSide(cardWidth: width)
        let shape = RoundedRectangle(cornerRadius: RoomCard.corner, style: .continuous)
        Button {
            router.addApp(path: nil, store: store)
        } label: {
            VStack(spacing: Space.s) {
                VStack(spacing: Space.s) {
                    StagedRoom(scene: scene, icon: .image(NSApp.applicationIconImage), side: side)
                        .overlay(alignment: .topTrailing) {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: max(20, side * 0.14)))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(Color.white, Color.accentColor)
                                .padding(Space.s)
                                .accessibilityHidden(true)
                        }
                    VStack(spacing: Space.xs) {
                        Text("Add App…")
                            .font(.headline)
                            .labelInk()
                            .lineLimit(1)
                        Text("From your Applications folder")
                            .font(.callout)
                            .labelInk()
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .padding(.vertical, 3)
                    }
                }
                // The height of the button row of an app card.
                Button("Start") {}
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .hidden()
                    .accessibilityHidden(true)
            }
            .padding(RoomSize.cardPadding)
            .frame(width: width)
            .background {
                shape.fill(Color(nsColor: .labelColor).opacity(RoomCardLook.veilOpacity(hovering: hovering)))
                    .accessibilityHidden(true)
            }
            .overlay {
                shape.strokeBorder(Color(nsColor: .secondaryLabelColor),
                                   style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                    .accessibilityHidden(true)
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(!store.binary.isUsable)
        .hoverLift(hovering)
        .onHover { hovering = $0 }
        .onDisappear { hovering = false }
        .animation(Motion.hover(reduceMotion), value: hovering)
        .help(Text("Add App…"))
        .accessibilityLabel(Text("Add App…"))
        .accessibilityIdentifier("add-room-card")
    }
}

/// How a room card shows hover and selection. The numbers are here so
/// the checks can read them.
enum RoomCardLook {
    /// The app icon next to the name of a card.
    static let nameIcon: CGFloat = 18

    /// The side of the stage in a card `cardWidth` wide.
    static func stageSide(cardWidth: CGFloat) -> CGFloat {
        max(0, cardWidth - 2 * RoomSize.cardPadding)
    }

    /// The edge of a card: the accent color for the selection while the
    /// grid has the keys, a gray ring while it has not, else a hairline.
    static func ring(selected: Bool, emphasized: Bool) -> Color {
        guard selected else { return Color(nsColor: .separatorColor) }
        return emphasized ? Color.accentColor : Color(nsColor: .secondaryLabelColor)
    }

    static func ringWidth(selected: Bool, emphasized: Bool, increasedContrast: Bool) -> CGFloat {
        guard selected else { return increasedContrast ? 2 : 1 }
        let width: CGFloat = emphasized ? 3 : 2
        return increasedContrast ? width + 1 : width
    }

    /// The accent wash over a selected card.
    static func washOpacity(selected: Bool, emphasized: Bool) -> Double {
        guard selected else { return 0 }
        return emphasized ? 0.12 : 0.05
    }

    /// The veil under the pointer: it darkens a light card and lightens
    /// a dark one.
    static func veilOpacity(hovering: Bool) -> Double {
        hovering ? 0.04 : 0
    }

    static func shadowOpacity(hovering: Bool) -> Double {
        hovering ? 0.16 : 0.06
    }

    static func shadowRadius(hovering: Bool) -> CGFloat {
        hovering ? 6 : 2
    }
}
