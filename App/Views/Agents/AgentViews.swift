import AppKit
import PaddockKit
import SwiftUI

// The agent rooms: the sidebar section, the state pill, the screen of the
// laptop, and the grid of rooms with the New Agent room at its end.

/// The laptop screen of an agent room: a dark terminal with a prompt in
/// the color of the character. Agents have no app icon.
@MainActor
enum AgentScreen {
    private static var cache: [CharacterColor: NSImage] = [:]

    static func image(_ color: CharacterColor) -> NSImage {
        if let image = cache[color] { return image }
        let side: CGFloat = 128
        let ink = NSColor(RoomPalette.character(color))
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor(srgbRed: 0.11, green: 0.12, blue: 0.14, alpha: 1).setFill()
            NSBezierPath(roundedRect: rect, xRadius: side * 0.12, yRadius: side * 0.12).fill()
            let font = NSFont.monospacedSystemFont(ofSize: side * 0.42, weight: .bold)
            let prompt = NSAttributedString(string: ">_", attributes: [.font: font, .foregroundColor: ink])
            let size = prompt.size()
            prompt.draw(at: NSPoint(x: (rect.width - size.width) / 2, y: (rect.height - size.height) / 2))
            return true
        }
        image.accessibilityDescription = nil
        cache[color] = image
        return image
    }
}

/// The state of a run as a pill: a symbol in the state's tint and the
/// state word. One element for VoiceOver.
@MainActor
struct AgentStatePill: View {
    let state: AgentState
    /// The word of the room when it differs from the word of the state:
    /// `Stopped` for a run that you stopped.
    var word: UIText?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 5) {
            if state == .starting {
                ProgressView().controlSize(.mini).accessibilityHidden(true)
            } else {
                Image(systemName: state.symbol.name)
                    .foregroundStyle(state.symbol.tint.color)
                    .accessibilityHidden(true)
            }
            Text(word ?? state.word)
        }
        .font(.callout)
        .labelInk()
        .lineLimit(1)
        .padding(.horizontal, Space.s)
        .padding(.vertical, 3)
        .quietCapsule()
        .animation(Motion.change(reduceMotion), value: state)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(word ?? state.word))
    }
}

/// The small "auto" tag of a run that works on its own. A run that asks
/// before each step, the default, has no tag. It only decorates: the
/// spoken line of the room says it.
@MainActor
struct AutoTag: View {
    var body: some View {
        Text(AgentCopy.autoTag)
            .font(.caption2.weight(.semibold))
            .labelInk()
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(Capsule().strokeBorder(Color(nsColor: .secondaryLabelColor), lineWidth: 1))
            .accessibilityHidden(true)
    }
}

/// The head of a character for the small places: a dot in its color with
/// the state symbol. It only decorates; the row says the state.
@MainActor
struct AgentBadge: View {
    let color: CharacterColor
    var size: CGFloat = IconSize.sidebar

    var body: some View {
        ZStack {
            Circle().fill(RoomPalette.character(color))
            Image(systemName: "terminal.fill")
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(Color.white)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Sidebar

/// The Agents section of the sidebar: the running and recent runs, a
/// "New Agent…" row, and the missing command of an older paddock.
@MainActor
struct AgentSidebarRows: View {
    @Environment(AgentStore.self) private var agents
    @Environment(LauncherStore.self) private var store
    @Environment(UIRouter.self) private var router

    var body: some View {
        Button {
            store.selection = .agents
        } label: {
            Text("Agents")
                .font(.subheadline)
                .labelInk()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .tag(SidebarItem.agents)
        .accessibilityAddTraits(.isHeader)
        .accessibilityLabel(Text("Agents"))
        .accessibilityIdentifier("sidebar-agents")
        ForEach(agents.rooms) { room in
            AgentRow(room: room)
                .tag(SidebarItem.agent(room.key))
                .contextMenu { AgentRowMenu(room: room) }
        }
        if agents.gaps.contains(.ps) {
            Text(AgentGap.ps.line)
                .font(.caption)
                .labelInk()
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("agents-needs-ps")
                .selectionDisabled()
        }
        Button {
            router.sheet = .newAgent(folder: nil)
        } label: {
            Label { Text("New Agent…").labelInk() } icon: { DecorativeSymbol(name: "plus.circle") }
        }
        .buttonStyle(.plain)
        .disabled(!store.binary.isUsable)
        .selectionDisabled()
        .accessibilityIdentifier("sidebar-new-agent")
    }
}

/// One agent in the sidebar: the character, `Claude Code in shop`, and
/// the state line under it. One element with the full spoken line.
@MainActor
struct AgentRow: View {
    let room: AgentRoom

    var body: some View {
        HStack(spacing: Space.s) {
            AgentBadge(color: room.color)
            VStack(alignment: .leading, spacing: 1) {
                Text(AgentCopy.title(room)).labelInk().lineLimit(1).truncationMode(.middle)
                HStack(spacing: Space.xs) {
                    Text(room.stateLine).font(.caption).labelInk().lineLimit(1)
                    if room.auto { AutoTag() }
                }
            }
            Spacer(minLength: Space.xs)
            if case .waiting(let count) = room.state {
                Text(verbatim: String(count))
                    .font(.caption.bold())
                    .monospacedDigit()
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 6)
                    .background(Capsule().fill(Color(nsColor: .systemRed)))
                    .accessibilityHidden(true)
            } else if room.state == .starting {
                ProgressView().controlSize(.small).accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(AgentCopy.spokenText(room)))
        .accessibilityIdentifier("agent-row-" + room.key)
    }
}

/// The context menu of an agent row and room.
@MainActor
struct AgentRowMenu: View {
    let room: AgentRoom
    @Environment(AgentStore.self) private var agents
    @Environment(LauncherStore.self) private var store
    @Environment(UIRouter.self) private var router

    var body: some View {
        if room.canStop {
            Button("Stop…") { router.sheet = .confirmStopAgent(room.key) }
        }
        if let id = room.runID, room.state.isLive {
            Button("Open in Terminal") { TerminalHandoffAction.open(runID: id) }
            // One pane per run: a run whose pane runs has nothing to reopen.
            if !room.paneRunning {
                Button("Reopen") {
                    if let key = agents.reopen(room) { store.selection = .agent(key) }
                }
            }
        }
        if let pane = room.paneID, !room.paneRunning {
            Divider()
            Button("Close") {
                agents.close(pane)
                TerminalPanes.shared.remove(pane)
                if store.selection == .agent(room.key) { store.selection = .agents }
            }
        }
    }
}

// MARK: - The rooms grid

/// The rooms of the agents, in the order of the section: what needs you
/// first. The arrow keys move the selection, Return opens the room. The
/// last card is the New Agent room.
@MainActor
struct AgentRoomsGrid: View {
    let open: (String) -> Void
    @Environment(AgentStore.self) private var agents
    @Environment(LauncherStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState
    @FocusState private var focused: Bool

    var body: some View {
        let rooms = agents.rooms
        let keys = rooms.map(\.key)
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
                                                                 alignment: .top), count: columns),
                              alignment: .leading, spacing: RoomsGrid.spacing) {
                        ForEach(Array(rooms.enumerated()), id: \.element.key) { index, room in
                            AgentRoomCard(room: room, index: index, width: cardWidth,
                                          selected: selectedKey == room.key, emphasized: emphasized,
                                          select: {
                                              store.selection = .agent(room.key)
                                              focused = true
                                          },
                                          open: { open(room.key) })
                                .id(room.key)
                                .transition(.roomCard(reduceMotion: reduceMotion))
                        }
                        NewAgentRoomCard(index: rooms.count, width: cardWidth)
                    }
                    .padding(RoomsGrid.margin)
                    .frame(maxWidth: .infinity, alignment: .top)
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
        .accessibilityLabel(Text("Agent rooms"))
        .accessibilityIdentifier("agent-rooms-grid")
    }

    private var selectedKey: String? {
        if case .agent(let key)? = store.selection { return key }
        return nil
    }

    private func move(_ move: RoomGridNavigation.Move, keys: [String], columns: Int) -> KeyPress.Result {
        let index = selectedKey.flatMap { keys.firstIndex(of: $0) }
        guard let next = RoomGridNavigation.move(index, move, count: keys.count, columns: columns) else { return .ignored }
        store.selection = .agent(keys[next])
        return .handled
    }
}

/// One agent room card: the room with the character of the agent, the
/// title, the state pill and one button: Stop while it runs, else Reopen
/// or nothing. The room, title and state are one element.
@MainActor
struct AgentRoomCard: View {
    let room: AgentRoom
    let index: Int
    let width: CGFloat
    let selected: Bool
    let emphasized: Bool
    let select: () -> Void
    let open: () -> Void
    @Environment(UIRouter.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var hovering = false

    var body: some View {
        VStack(spacing: Space.s) {
            VStack(spacing: Space.s) {
                AgentStagedRoom(room: room, index: index, side: RoomCardLook.stageSide(cardWidth: width),
                                zoom: .source(room.key))
                VStack(spacing: Space.xs) {
                    HStack(spacing: Space.xs) {
                        AgentBadge(color: room.color, size: RoomCardLook.nameIcon)
                        Text(AgentCopy.title(room))
                            .font(.headline)
                            .labelInk()
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    HStack(spacing: Space.xs) {
                        AgentStatePill(state: room.state, word: room.stateWord)
                        if room.auto { AutoTag() }
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(TapGesture(count: 2).onEnded { open() })
            .simultaneousGesture(TapGesture().onEnded { select() })
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(AgentCopy.spokenText(room)))
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { open() }
            .accessibilityIdentifier("agent-card-" + room.key)
            primaryButton
        }
        .padding(RoomSize.cardPadding)
        .frame(width: width)
        .background {
            let shape = RoundedRectangle(cornerRadius: RoomCard.corner, style: .continuous)
            shape.fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: Color.black.opacity(RoomCardLook.shadowOpacity(hovering: hovering)),
                        radius: RoomCardLook.shadowRadius(hovering: hovering), x: 0, y: hovering ? 2 : 1)
                .overlay { shape.fill(Color.accentColor.opacity(RoomCardLook.washOpacity(selected: selected, emphasized: emphasized))) }
                .overlay { shape.fill(Color(nsColor: .labelColor).opacity(RoomCardLook.veilOpacity(hovering: hovering))) }
                .accessibilityHidden(true)
        }
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
        .contextMenu { AgentRowMenu(room: room) }
    }

    /// Open (the pane or the detail) for every room; the height stays, so
    /// the cards line up. The selected card has the prominent button.
    @ViewBuilder private var primaryButton: some View {
        let title: LocalizedStringKey = room.state.isLive || room.paneRunning ? "Open" : "Details" // localized
        Button(title) { open() }
            .modifier(SessionButtonStyle(primary: selected))
            .controlSize(.regular)
            .accessibilityHint(Text(AgentCopy.title(room)))
            .accessibilityIdentifier("agent-primary-" + room.key)
    }
}

/// The last card of the agents grid: an empty room with the gray
/// character awake and a plus. A click opens the New Agent sheet.
@MainActor
struct NewAgentRoomCard: View {
    let index: Int
    let width: CGFloat
    @Environment(LauncherStore.self) private var store
    @Environment(UIRouter.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        let side = RoomCardLook.stageSide(cardWidth: width)
        let shape = RoundedRectangle(cornerRadius: RoomCard.corner, style: .continuous)
        Button {
            router.sheet = .newAgent(folder: nil)
        } label: {
            VStack(spacing: Space.s) {
                StagedRoom(scene: RoomScene(tint: .at(index), color: .gray, pose: .idle),
                           icon: .image(AgentScreen.image(.gray)), side: side)
                    .overlay(alignment: .topTrailing) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: max(20, side * 0.14)))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(Color.white, Color.accentColor)
                            .padding(Space.s)
                            .accessibilityHidden(true)
                    }
                Text("New Agent…").font(.headline).labelInk().lineLimit(1)
                Text("Start an agent on a project folder").font(.callout).labelInk().lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(RoomSize.cardPadding)
            .frame(width: width)
            .background {
                shape.fill(Color(nsColor: .labelColor).opacity(RoomCardLook.veilOpacity(hovering: hovering)))
                    .accessibilityHidden(true)
            }
            .overlay {
                shape.strokeBorder(Color(nsColor: .secondaryLabelColor), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                    .accessibilityHidden(true)
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(!store.binary.isUsable)
        .onHover { hovering = $0 }
        .onDisappear { hovering = false }
        .animation(Motion.hover(reduceMotion), value: hovering)
        .help(Text("New Agent…"))
        .accessibilityLabel(Text("New Agent…"))
        .accessibilityIdentifier("new-agent-room-card")
    }
}

/// The Agents section in the detail: the rooms grid, and the room of a
/// run after Return or a double click. In the List layout a selected run
/// shows its room at once.
@MainActor
struct AgentsDetail: View {
    @Environment(AgentStore.self) private var agents
    @Environment(LauncherStore.self) private var store
    @Environment(UIRouter.self) private var router
    @State private var path: [String] = []

    var body: some View {
        Group {
            if case .agent(let key)? = store.selection, router.libraryLayout == .list {
                AgentDetailView(key: key)
                    .id(key)
                    .transition(Motion.enter)
            } else if agents.rooms.isEmpty {
                NoAgentsView()
            } else {
                NavigationStack(path: $path) {
                    AgentRoomsGrid(open: open)
                        .navigationDestination(for: String.self) { key in
                            AgentDetailView(key: key).id(key)
                        }
                }
                .onChange(of: store.selection) { _, selection in
                    guard let shown = path.last else { return }
                    if case .agent(let key)? = selection, key != shown { path = [key] }
                    if selection == .agents { path = [] }
                }
            }
        }
        // A run that just started, or that a notice points to: its pane
        // opens in the Rooms layout too, not only its card in the grid.
        .onChange(of: store.openRoom, initial: true) { _, room in
            guard case .agent(let key)? = room else { return }
            if router.libraryLayout == .rooms, agents.room(key) != nil { path = [key] }
            store.openRoom = nil
        }
    }

    private func open(_ key: String) {
        store.selection = .agent(key)
        path = [key]
    }
}

/// No agent runs yet: the gray character in an empty room, one sentence
/// and the one action, New Agent.
///
/// When paddock listed its agents and found none on this Mac, the page
/// says that, and offers to look again: New Agent alone would lead to a
/// list with nothing to choose.
@MainActor
struct NoAgentsView: View {
    @Environment(AgentStore.self) private var agents
    @Environment(LauncherStore.self) private var store
    @Environment(UIRouter.self) private var router
    @State private var looking = false

    private var kind: AgentsEmpty {
        // The agents only: paddock's list also has desktop apps. A list
        // that paddock could not give says nothing about this Mac.
        AgentsEmpty.of(loaded: agents.harnessesLoaded && !agents.gaps.contains(.list),
                       installed: agents.agentHarnesses.filter(\.installed).count)
    }

    var body: some View {
        let kind = self.kind
        PlainEmpty {
            VStack(spacing: Space.l) {
                StagedRoom(scene: RoomScene(tint: .cream, color: .gray, pose: .sleep),
                           icon: .image(AgentScreen.image(.gray)), side: RoomSize.welcome)
                Text(kind.title).font(.title2.bold())
                    .accessibilityIdentifier("agents-empty-title")
            }
        } description: {
            Text(kind.text)
        } actions: {
            VStack(spacing: Space.m) {
                if kind == .noneInstalled {
                    // The shell once more, then paddock's list with its PATH.
                    Button("Look Again") {
                        looking = true
                        Task {
                            await AppContainer.lookAgain()
                            looking = false
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(looking || !store.binary.isUsable)
                    .accessibilityIdentifier("agents-look-again")
                    if agents.usesFallbackPath {
                        Text(WelcomeCopy.shellFallback).font(.callout).labelInk()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Button("New Agent…") { router.sheet = .newAgent(folder: nil) }
                    .modifier(SessionButtonStyle(primary: kind == .noRuns))
                    .controlSize(.large)
                    .disabled(!store.binary.isUsable)
                    .accessibilityIdentifier("empty-new-agent")
                ForEach(AgentGap.allCases.filter { agents.gaps.contains($0) }, id: \.self) { gap in
                    Text(gap.line).font(.callout).labelInk()
                        .accessibilityIdentifier("agents-needs-" + gap.rawValue)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(kind.title))
        .accessibilityIdentifier("agents-empty")
    }
}
