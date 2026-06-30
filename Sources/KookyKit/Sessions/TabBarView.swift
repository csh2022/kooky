import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Per-pane tab strip — each split region renders its own. The "+" button
/// targets the pane it sits in.
struct TabBarView: View {
    @Bindable var pane: Pane
    @Bindable var workspace: Workspace
    let store: WorkspaceStore

    @State private var isAddMenuOpen = false
    @State private var previewIndex: Int?

    private let tabSpacing: CGFloat = 2
    private let horizontalPadding: CGFloat = Theme.space2
    private let addButtonWidth: CGFloat = 28
    private let splitControlsWidth: CGFloat = 64
    private let titleRowDropPadding: CGFloat = 18

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: tabSpacing) {
                    ForEach(Array(pane.tabs.enumerated()), id: \.element.id) { index, tab in
                        if previewIndex == index { TabDropPlaceholder() }
                        DraggableTabRow(
                            tab: tab,
                            pane: pane,
                            workspace: workspace,
                            store: store,
                            myIndex: index,
                            canCloseToRight: index < pane.tabs.count - 1
                        )
                    }
                    if previewIndex == pane.tabs.count { TabDropPlaceholder() }
                    addButton
                }
                .padding(.horizontal, horizontalPadding)
            }

            // Split controls pinned to the trailing edge — outside the
            // ScrollView so they stay put while the tabs scroll.
            splitButtons
        }
        .frame(height: 40)
        .background(tabBarDropSurface)
    }

    /// Split-right / split-down buttons. Mirror ⌘D / ⌘⇧D exactly: Split
    /// Right is the `.horizontal` orientation (panes side by side), Split
    /// Down is `.vertical` (panes stacked) — same mapping as
    /// `AppDelegate.handleSplitRight` / `handleSplitDown`.
    private var splitButtons: some View {
        HStack(spacing: 2) {
            HoverableIconButton(
                systemName: "square.split.2x1",
                fontSize: 12,
                size: 28,
                help: "Split Right (⌘D)"
            ) {
                store.splitPane(pane, orientation: .horizontal, in: workspace)
            }
            HoverableIconButton(
                systemName: "square.split.1x2",
                fontSize: 12,
                size: 28,
                help: "Split Down (⌘⇧D)"
            ) {
                store.splitPane(pane, orientation: .vertical, in: workspace)
            }
        }
        .padding(.trailing, Theme.space2)
    }

    private var addButton: some View {
        AddTabButton(
            pane: pane,
            workspace: workspace,
            store: store,
            isMenuOpen: $isAddMenuOpen
        )
    }

    private var tabBarDropSurface: some View {
        TabBarDropSurface(
            pane: pane,
            store: store,
            tabWidth: TabBarItem.layoutWidth,
            tabSpacing: tabSpacing,
            horizontalPadding: horizontalPadding,
            addButtonWidth: addButtonWidth,
            trailingDropWidth: splitControlsWidth,
            verticalPadding: titleRowDropPadding,
            previewIndex: $previewIndex,
            onDrop: { id, index in
                withAnimation(.easeInOut(duration: 0.18)) {
                    store.handleTabDrop(droppedId: id, to: pane, at: index, in: workspace)
                }
            }
        )
    }
}

/// `+` button doubling as the "drop at end" target — dragging a tab here
/// (from this pane or another) appends it after the last tab, which is
/// otherwise unreachable inside a horizontal `ScrollView` where there's no
/// flex space for a trailing drop zone.
private struct AddTabButton: View {
    @Bindable var pane: Pane
    @Bindable var workspace: Workspace
    @Bindable var store: WorkspaceStore
    @Binding var isMenuOpen: Bool

    @State private var isTargeted = false

    var body: some View {
        HoverableIconButton(
            systemName: "plus",
            fontSize: 12,
            size: 28,
            help: "New tab"
        ) {
            // Two short-circuit paths that skip the popover entirely:
            //   1. user picked a default agent in Settings — open it
            //   2. every coding agent is hidden so the popover would show
            //      just Terminal anyway — open Terminal
            let model = KookySettingsModel.shared
            if let defaultTemplate = AgentTemplate.defaultLaunchTemplate(model: model) {
                store.addTab(in: workspace, pane: pane, template: defaultTemplate)
            } else if AgentTemplate.visibleOrdered(model: model).count <= 1 {
                store.addTab(in: workspace, pane: pane, template: .terminal)
            } else {
                isMenuOpen.toggle()
            }
        }
        .dropIndicator(active: isTargeted, on: .leading, offset: -3)
        .popover(isPresented: $isMenuOpen, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(AgentTemplate.visibleOrdered(model: KookySettingsModel.shared)) { template in
                    KookyMenuRow(title: template.title) {
                        AgentIconView(asset: template.iconAsset, fallbackSymbol: template.symbol, size: 16)
                    } action: {
                        store.addTab(in: workspace, pane: pane, template: template)
                        isMenuOpen = false
                    }
                }
            }
            .padding(Theme.space1)
            .frame(minWidth: 220)
            .background(Theme.chromeBackground)
        }
        .dropDestination(for: String.self) { dropped, _ in
            defer { store.draggingTabId = nil }
            guard let id = dropped.first.flatMap(KookyDragPayload.tabId) else { return false }
            return withAnimation(.easeInOut(duration: 0.18)) {
                store.handleTabDrop(droppedId: id, to: pane, at: pane.tabs.count, in: workspace)
            }
        } isTargeted: { isTargeted = $0 }
    }
}

/// Wraps `TabBarItem` with drag source + drop target. Same-pane drops
/// reorder; cross-pane drops move the session into this pane (source pane
/// collapses if it runs out of tabs). The 2pt indicator follows drag
/// direction — `leading` for left-of-target sources, `trailing` for
/// right-of-target — so the line always shows where the dropped tab lands.
private struct DraggableTabRow: View {
    @Bindable var tab: Session
    @Bindable var pane: Pane
    @Bindable var workspace: Workspace
    @Bindable var store: WorkspaceStore
    let myIndex: Int
    let canCloseToRight: Bool

    @State private var isTargeted = false

    var body: some View {
        let originIndex: Int? = {
            guard let id = store.draggingTabId, id != tab.id else { return nil }
            return pane.tabs.firstIndex(where: { $0.id == id })
        }()
        let dragsRightward = (originIndex ?? Int.max) < myIndex
        let edge: Alignment = dragsRightward ? .trailing : .leading
        let isSelfDrag = store.draggingTabId == tab.id

        TabBarItem(
            tab: tab,
            isActive: pane.activeTabId == tab.id,
            canCloseToRight: canCloseToRight,
            onActivate: { store.activateTab(tab, in: workspace) },
            onClose: { store.requestCloseTab(tab, in: workspace) },
            onCloseOthers: { store.requestCloseOtherTabs(keeping: tab, in: workspace) },
            onCloseToRight: { store.requestCloseTabsToRight(of: tab, in: workspace) },
            onDuplicate: { store.duplicateTab(tab, in: workspace) },
            onRename: { store.renameTab(tab, to: $0) },
            onSplit: { store.splitPane(pane, orientation: $0, in: workspace) },
            onMoveToNewWindow: { store.moveTabToNewWindow(tab.id) }
        )
        .dropIndicator(active: isTargeted && !isSelfDrag, on: edge)
        .onDrag {
            store.draggingTabId = tab.id
            return NSItemProvider(object: KookyDragPayload.tab(tab.id).encoded as NSString)
        }
        .dropDestination(for: String.self) { dropped, _ in
            defer { store.draggingTabId = nil }
            guard let id = dropped.first.flatMap(KookyDragPayload.tabId) else { return false }
            return withAnimation(.easeInOut(duration: 0.18)) {
                store.handleTabDrop(droppedId: id, to: pane, at: myIndex, in: workspace)
            }
        } isTargeted: { isTargeted = $0 }
    }
}

private struct TabDropPlaceholder: View {
    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(Theme.chromeForeground.opacity(0.28))
                .frame(width: 5, height: 5)
            RoundedRectangle(cornerRadius: 3)
                .fill(Theme.chromeForeground.opacity(0.32))
                .frame(width: 15, height: 15)
            Text("Drop tab here")
                .font(Theme.display(12, weight: .regular))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(Theme.chromeForeground.opacity(0.7))
        .padding(.horizontal, Theme.space3)
        .padding(.vertical, 7)
        .frame(width: TabBarItem.layoutWidth, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Theme.chromeForeground.opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Theme.chromeForeground.opacity(0.65), lineWidth: 1.5)
                )
        )
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
        .allowsHitTesting(false)
    }
}

private struct TabBarDropSurface: NSViewRepresentable {
    @Bindable var pane: Pane
    @Bindable var store: WorkspaceStore
    let tabWidth: CGFloat
    let tabSpacing: CGFloat
    let horizontalPadding: CGFloat
    let addButtonWidth: CGFloat
    let trailingDropWidth: CGFloat
    let verticalPadding: CGFloat
    @Binding var previewIndex: Int?
    let onDrop: (UUID, Int) -> Bool

    func makeNSView(context: Context) -> TabBarDropNSView {
        let view = TabBarDropNSView()
        view.onEnteredOrUpdated = { point in
            guard store.draggingTabId != nil, isInsideTitleDropBand(point) else {
                previewIndex = nil
                return
            }
            previewIndex = insertionIndex(forX: point.x)
        }
        view.onExited = { previewIndex = nil }
        view.onDrop = { point, raw in
            defer {
                store.draggingTabId = nil
                previewIndex = nil
            }
            guard let id = KookyDragPayload.tabId(from: raw), isInsideTitleDropBand(point) else { return false }
            return onDrop(id, insertionIndex(forX: point.x))
        }
        return view
    }

    func updateNSView(_ nsView: TabBarDropNSView, context: Context) {}

    private func insertionIndex(forX rawX: CGFloat) -> Int {
        let x = max(0, rawX - horizontalPadding)
        let tabStride = tabWidth + tabSpacing
        let tabCount = pane.tabs.count
        for index in 0..<tabCount {
            let mid = CGFloat(index) * tabStride + tabWidth / 2
            if x < mid { return index }
        }
        return tabCount
    }

    private func isInsideTitleDropBand(_ point: CGPoint) -> Bool {
        point.y >= -verticalPadding && point.y <= 40 + verticalPadding
    }
}

private final class TabBarDropNSView: NSView {
    var onEnteredOrUpdated: ((CGPoint) -> Void)?
    var onExited: (() -> Void)?
    var onDrop: ((CGPoint, String) -> Bool)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.string])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard draggingString(sender) != nil else { return [] }
        onEnteredOrUpdated?(convert(sender.draggingLocation, from: nil))
        return .move
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard draggingString(sender) != nil else { return [] }
        onEnteredOrUpdated?(convert(sender.draggingLocation, from: nil))
        return .move
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        onExited?()
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let raw = draggingString(sender) else { return false }
        return onDrop?(convert(sender.draggingLocation, from: nil), raw) ?? false
    }

    private func draggingString(_ sender: any NSDraggingInfo) -> String? {
        sender.draggingPasteboard.string(forType: .string)
    }
}
