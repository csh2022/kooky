import SwiftUI

/// Recursive view for a workspace's split tree. Leaves render their own tab
/// strip + active terminal — a split slices the whole tab strip, not just
/// the content area.
struct PaneTreeView: View {
    @Bindable var node: PaneNode
    @Bindable var workspace: Workspace
    let store: WorkspaceStore

    var body: some View {
        switch node.content {
        case .pane(let pane):
            PaneView(
                pane: pane,
                workspace: workspace,
                store: store,
                isFocused: workspace.activePaneId == pane.id
            )
        case .split:
            SplitContainer(node: node, workspace: workspace, store: store)
        }
    }
}

private struct PaneView: View {
    @Bindable var pane: Pane
    @Bindable var workspace: Workspace
    @Bindable var store: WorkspaceStore
    let isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            TabBarView(pane: pane, workspace: workspace, store: store)
            Rectangle().fill(Theme.chromeHairline).frame(height: 1)
            if let active = pane.activeTab {
                TerminalView(engine: active.engine)
                    .id(active.id)
                    .padding(8)
                    .overlay(alignment: .topTrailing) {
                        // Per-pane: multiple panes can search simultaneously,
                        // each with their own needle and result count.
                        if active.searchActive {
                            PaneSearchBar(
                                session: active,
                                onFocusGained: { store.activateTab(active, in: workspace) }
                            )
                            .padding(.top, Theme.space3)
                            .padding(.trailing, Theme.space3)
                        }
                    }
                if active.gitStatus.branch != nil || !active.environment.isEmpty {
                    Rectangle().fill(Theme.chromeHairline).frame(height: 1)
                    PaneStatusBar(session: active)
                }
            } else {
                Color.clear
            }
        }
    }
}

/// Chrome status bar pinned to the bottom of the active pane — Warp-style
/// approximation. libghostty owns the terminal grid, so we can't inline
/// above the prompt; pinning to chrome below the terminal is the closest
/// equivalent. Each segment is its own bordered pill with leading icon,
/// stacked right-aligned. Hidden entirely when no segment has data.
private struct PaneStatusBar: View {
    @Bindable var session: Session

    var body: some View {
        // Order: project context (changes rarely) on the left, working-tree
        // state (changes per save / commit) on the right. Eyes scanning
        // right-to-left hit "what changed" first, then "what project context".
        // ViewThatFits picks the first variant whose intrinsic width fits the
        // pane — when splits get narrow, slots drop by priority instead of
        // truncating mid-glyph or wrapping into a second row.
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            ViewThatFits(in: .horizontal) {
                segmentRow([pythonSegment, nodeSegment, branchSegment, diffSegment])
                segmentRow([nodeSegment, branchSegment, diffSegment])
                segmentRow([branchSegment, diffSegment])
                segmentRow([diffSegment])
                segmentRow([branchSegment])
            }
        }
        .font(Theme.mono(11))
        .padding(.horizontal, Theme.space4)
        .padding(.vertical, 5)
        .background(Theme.chromeBackground)
    }

    private func segmentRow(_ segments: [AnyView]) -> some View {
        HStack(spacing: 8) { ForEach(0..<segments.count, id: \.self) { segments[$0] } }
    }

    private var pythonSegment: AnyView {
        guard let venv = session.environment.pythonVenv else { return AnyView(EmptyView()) }
        return AnyView(StatusSegment(systemImage: "p.circle.fill") {
            Text(venv).foregroundStyle(Theme.chromeForeground)
        })
    }

    private var nodeSegment: AnyView {
        guard let version = session.environment.nodeVersion else { return AnyView(EmptyView()) }
        let nvmDir = session.environment.nvmDirectory
        return AnyView(SwitchableStatusSegment<String>(
            systemImage: "n.circle.fill",
            label: version,
            helpText: "Switch Node version",
            popoverWidth: 190,
            popoverMaxHeight: 280,
            emptyMessage: "No nvm versions found",
            loadItems: { NodeVersionInventory.installedVersions(nvmDirectory: nvmDir) },
            isCurrent: { NodeVersionInventory.isSameVersion($0, version) },
            titleFor: { $0 },
            commandFor: NodeVersionInventory.shellUseCommand,
            session: session
        ))
    }

    private var branchSegment: AnyView {
        guard let branch = session.gitStatus.branch else { return AnyView(EmptyView()) }
        let cwd = session.currentDirectory
        return AnyView(SwitchableStatusSegment<String>(
            systemImage: "arrow.triangle.branch",
            label: branch,
            helpText: "Switch Git branch",
            popoverWidth: 230,
            popoverMaxHeight: 320,
            emptyMessage: "No local branches found",
            loadItems: { GitBranchInventory.localBranches(cwd: cwd) },
            isCurrent: { $0 == branch },
            titleFor: { $0 },
            commandFor: GitBranchInventory.shellSwitchCommand,
            session: session
        ))
    }

    private var diffSegment: AnyView {
        let s = session.gitStatus
        guard s.branch != nil, s.filesChanged > 0 else { return AnyView(EmptyView()) }
        return AnyView(StatusSegment(systemImage: "line.3.horizontal.button.angledtop.vertical.right") {
            // Order mirrors `git diff --shortstat` itself: files → +N → −N.
            // File count in chromeMuted (it's a count, not a delta) so the
            // saturated +/- pair pops as the actual change signal.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(s.filesChanged)")
                    .foregroundStyle(Theme.chromeMuted)
                if s.insertions > 0 {
                    SignedNumber(sign: "+", value: s.insertions, color: Theme.gitInsertion)
                }
                if s.deletions > 0 {
                    // Unicode minus (U+2212), not hyphen — balanced
                    // typographic pair with `+`.
                    SignedNumber(sign: "−", value: s.deletions, color: Theme.gitDeletion)
                }
            }
        })
    }
}

/// One bordered segment of the status bar — leading SF Symbol icon at
/// `chromeMuted`, body content rendered by the caller. Wraps each
/// data-source (git, Python env, Node version, …) in a uniform pill so
/// adding new sources is just `StatusSegment(systemImage: ...) { ... }`.
private struct StatusSegment<Content: View>: View {
    let systemImage: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: systemImage)
                .imageScale(.small)
                .foregroundStyle(Theme.chromeMuted)
            content()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Theme.chromeFaint, lineWidth: 1)
        )
    }
}

/// `+47` / `−12` as one cohesive typographic token — sign rendered at 60%
/// saturation of its digit creates a subtle hierarchical stagger that reads
/// as designed, not as a UI widget. JetBrains Mono is fixed-width, so the
/// two-Text HStack stays optically tight without manual kerning.
private struct SignedNumber: View {
    let sign: String
    let value: Int
    let color: Color

    var body: some View {
        HStack(spacing: 0) {
            Text(sign).foregroundStyle(color.opacity(0.6))
            Text("\(value)").foregroundStyle(color)
        }
    }
}

/// A `StatusSegment` you can click — opens a popover listing alternatives,
/// click one to inject a shell command. Shared shell for both the Node
/// version switcher and the git branch switcher; new switchers (Python
/// versions, mise tools, …) just instantiate with their own loader +
/// formatter.
///
/// `loadItems` is called only on click, not on `onAppear` — popover content
/// is what triggers the inventory work, so a tab the user never opens the
/// switcher on does zero filesystem / subprocess.
private struct SwitchableStatusSegment<Item: Hashable>: View {
    let systemImage: String
    let label: String
    let helpText: String
    let popoverWidth: CGFloat
    let popoverMaxHeight: CGFloat
    let emptyMessage: String
    let loadItems: () -> [Item]
    let isCurrent: (Item) -> Bool
    let titleFor: (Item) -> String
    let commandFor: (Item) -> String
    let session: Session

    @State private var isSwitcherOpen = false
    @State private var isHovered = false
    @State private var items: [Item] = []

    var body: some View {
        Button {
            items = loadItems()
            isSwitcherOpen.toggle()
        } label: {
            StatusSegment(systemImage: systemImage) {
                Text(label)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(Theme.chromeForeground)
            }
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isHovered || isSwitcherOpen ? Theme.chromeHover : .clear)
            )
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 4))
        .help(helpText)
        .onHover { isHovered = $0 }
        .popover(isPresented: $isSwitcherOpen, arrowEdge: .bottom) {
            KookyMenuList(width: popoverWidth, maxHeight: popoverMaxHeight) {
                if items.isEmpty {
                    KookyMenuRow(title: emptyMessage, isDisabled: true) {}
                } else {
                    ForEach(items, id: \.self) { item in
                        let current = isCurrent(item)
                        KookyMenuRow(
                            title: titleFor(item),
                            isDisabled: current,
                            leading: { menuRowCheckmark(visible: current) }
                        ) {
                            isSwitcherOpen = false
                            session.engine.sendInput(commandFor(item))
                        }
                    }
                }
            }
        }
    }
}

/// Scrollable menu shell shared by every popover in the status bar (and
/// future ones). Width varies per call site; vertical chrome and bg are
/// constant. Keeps `KookyMenuRow`'s sibling layout consistent across the
/// app.
private struct KookyMenuList<Content: View>: View {
    let width: CGFloat
    let maxHeight: CGFloat
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(spacing: 2, content: content).padding(6)
        }
        .frame(width: width)
        .frame(maxHeight: maxHeight)
        .background(Theme.chromeBackground)
    }
}

@ViewBuilder
private func menuRowCheckmark(visible: Bool) -> some View {
    if visible {
        Image(systemName: "checkmark")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.chromeForeground)
            .frame(width: 14)
    } else {
        Color.clear.frame(width: 14, height: 11)
    }
}

/// Editable search field overlaying the active pane's terminal area.
/// Each keystroke pushes `search:<text>` to libghostty (the named action
/// that updates the needle and re-runs the search). Auto-focuses when
/// search activates so Esc / Enter route here instead of to the terminal
/// NSView. Lives in `PaneTreeView` because search state belongs visually
/// next to the content it filters — not in the global window chrome.
private struct PaneSearchBar: View {
    @Bindable var session: Session
    /// Called when the TextField gains focus so the parent can promote this
    /// pane to active. Without this, clicking a non-active pane's search bar
    /// leaves `WorkspaceStore.activePaneId` unchanged, and ⌘G / ⌘⇧G route
    /// `navigate_search` to the wrong session.
    let onFocusGained: () -> Void
    @State private var needle = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: Theme.space2) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(Theme.chromeMuted)
            TextField("Search…", text: $needle)
                .textFieldStyle(.plain)
                .font(Theme.mono(11.5))
                .foregroundStyle(Theme.chromeForeground)
                .focused($focused)
                .onChange(of: needle) { _, new in
                    // Persist the needle on the session so it survives a tab
                    // switch (which destroys this view; `onAppear` re-seeds
                    // from `session.searchNeedle`). libghostty's `START_SEARCH`
                    // action_cb writes the same field but only fires on initial
                    // start_search, not on per-keystroke updates.
                    session.searchNeedle = new
                    // `search:<text>` is libghostty's "update the search needle"
                    // action. Empty cancels matches but keeps the GUI open per
                    // libghostty's docs — we end_search explicitly on Esc / X.
                    session.engine.performAction("search:\(new)")
                }
                .onSubmit {
                    session.engine.performAction("navigate_search:next")
                }
                .onKeyPress(.escape) {
                    end()
                    return .handled
                }
            if session.searchTotal > 0 {
                Text(counterText)
                    .font(Theme.mono(10.5))
                    .foregroundStyle(Theme.chromeMuted)
                    .frame(minWidth: 50, alignment: .trailing)
            }
            HoverableIconButton(systemName: "chevron.up", fontSize: 10, size: 20, help: "Previous match (⌘⇧G)") {
                session.engine.performAction("navigate_search:previous")
            }
            HoverableIconButton(systemName: "chevron.down", fontSize: 10, size: 20, help: "Next match (⌘G)") {
                session.engine.performAction("navigate_search:next")
            }
            HoverableIconButton(systemName: "xmark", fontSize: 10, size: 20, help: "End search (Esc)") {
                end()
            }
        }
        .padding(.horizontal, Theme.space3)
        .padding(.vertical, 5)
        .frame(width: 340)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Theme.chromeBackground.opacity(0.96))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Theme.chromeHairline, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
        )
        .onAppear {
            // Seed from libghostty's start-search needle so a future
            // `start_search:<text>` keybind (or selected-text seeding) carries
            // through to the visible TextField. Empty in the common case.
            needle = session.searchNeedle
            focused = true
        }
        .onChange(of: focused) { _, isFocused in
            if isFocused { onFocusGained() }
        }
    }

    private func end() {
        focused = false
        session.engine.performAction("end_search")
    }

    /// "i / total" once the user has navigated to a specific match;
    /// the bare match count while libghostty's `selected = -1` (no current
    /// match highlighted yet).
    private var counterText: String {
        guard session.searchSelected >= 0 else { return "\(session.searchTotal)" }
        return "\(session.searchSelected + 1) / \(session.searchTotal)"
    }
}

private struct SplitContainer: View {
    @Bindable var node: PaneNode
    @Bindable var workspace: Workspace
    let store: WorkspaceStore

    @State private var dragStartFraction: Double?

    private static let dividerThickness: CGFloat = 1
    private static let handleHitSize: CGFloat = 6
    private static let minFraction: Double = 0.1
    private static let maxFraction: Double = 0.9

    var body: some View {
        guard case .split(let orientation, let first, let second, let fraction) = node.content else {
            return AnyView(EmptyView())
        }
        return AnyView(
            GeometryReader { geo in
                let total: CGFloat = orientation == .horizontal ? geo.size.width : geo.size.height
                let usable = max(total - Self.dividerThickness, 0)
                let firstSize = max(0, usable * fraction)
                let secondSize = max(0, usable - firstSize)
                let handleOffset = firstSize - Self.handleHitSize / 2 + Self.dividerThickness / 2

                ZStack(alignment: orientation == .horizontal ? .leading : .top) {
                    if orientation == .horizontal {
                        HStack(spacing: 0) {
                            PaneTreeView(node: first, workspace: workspace, store: store).frame(width: firstSize)
                            Rectangle().fill(Theme.chromeHairline).frame(width: Self.dividerThickness)
                            PaneTreeView(node: second, workspace: workspace, store: store).frame(width: secondSize)
                        }
                        DividerHandle(orientation: .horizontal)
                            .frame(width: Self.handleHitSize, height: geo.size.height)
                            .offset(x: handleOffset, y: 0)
                            .gesture(dragGesture(orientation: orientation, total: total))
                    } else {
                        VStack(spacing: 0) {
                            PaneTreeView(node: first, workspace: workspace, store: store).frame(height: firstSize)
                            Rectangle().fill(Theme.chromeHairline).frame(height: Self.dividerThickness)
                            PaneTreeView(node: second, workspace: workspace, store: store).frame(height: secondSize)
                        }
                        DividerHandle(orientation: .vertical)
                            .frame(width: geo.size.width, height: Self.handleHitSize)
                            .offset(x: 0, y: handleOffset)
                            .gesture(dragGesture(orientation: orientation, total: total))
                    }
                }
            }
        )
    }

    private func dragGesture(orientation: SplitOrientation, total: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard case .split(let orient, let f, let s, let current) = node.content else { return }
                if dragStartFraction == nil { dragStartFraction = current }
                let translation = orientation == .horizontal ? value.translation.width : value.translation.height
                let delta = total > 0 ? Double(translation) / Double(total) : 0
                let proposed = (dragStartFraction ?? current) + delta
                let clamped = min(max(proposed, Self.minFraction), Self.maxFraction)
                guard abs(clamped - current) > .ulpOfOne else { return }
                node.content = .split(orientation: orient, first: f, second: s, fraction: clamped)
            }
            .onEnded { _ in
                dragStartFraction = nil
                store.flushPersistence()
            }
    }
}

private struct DividerHandle: View {
    let orientation: SplitOrientation

    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.001))
            .contentShape(Rectangle())
            .onHover { isHovered in
                if isHovered {
                    if orientation == .horizontal {
                        NSCursor.resizeLeftRight.push()
                    } else {
                        NSCursor.resizeUpDown.push()
                    }
                } else {
                    NSCursor.pop()
                }
            }
    }
}
