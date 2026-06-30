import SwiftUI

/// Bundles modal sheets owned by the sidebar so they share one
/// `.sheet(item:)` modifier. Shortcut/menu-driven close confirmations and
/// worktree close flows live at `ContentView` level so they still work when
/// the sidebar is hidden.
private enum SidebarSheet: Identifiable {
    case createWorktree(Workspace)

    var id: String {
        switch self {
        case .createWorktree(let ws): return "create-\(ws.id.uuidString)"
        }
    }
}

struct SidebarView: View {
    static let fullWidth: CGFloat = 220
    static let compactWidth: CGFloat = 52
    @Bindable var store: WorkspaceStore
    /// Id of the workspace currently being dragged. Set by `.onDrag`, cleared
    /// on drop. Lets each row compute whether the drag origin is above or
    /// below it so the drop indicator can flip edges.
    @State private var draggingWorkspaceId: UUID?
    /// True while a Finder folder drag is hovering the sidebar — gates the
    /// drop-zone outline so the user sees that releasing here opens a new
    /// workspace.
    @State private var isFolderDropTargeted = false
    /// Source workspace ids whose worktree subtree the user collapsed.
    /// Default behaviour is expanded — only ids the user explicitly closed
    /// land here. Ephemeral by design: a kooky relaunch always shows every
    /// worktree on first paint so nothing is hidden by stale state.
    @State private var collapsedParents: Set<UUID> = []
    /// Active modal sheet for sidebar-owned flows.
    /// Nil = no sheet. Set by row callbacks and an onChange observer that
    /// watches global create requests.
    @State private var sheet: SidebarSheet?

    var body: some View {
        let isCompact = store.sidebarMode == .compact
        VStack(spacing: 0) {
            brand(isCompact: isCompact)
            ScrollViewReader { proxy in
                list(isCompact: isCompact, proxy: proxy)
            }
            Spacer(minLength: 0)
        }
        .frame(width: isCompact ? Self.compactWidth : Self.fullWidth)
        .background(Theme.chromeBackground)
        .overlay {
            // Drop affordance: tinted fill + hairline stroke, inset from the
            // sidebar edges so the splitter / titlebar don't clip it. Always
            // in the view tree (alpha-driven) so `easeOut(0.12)` can animate.
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Theme.chromeActive)
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Theme.chromeForeground.opacity(0.55), lineWidth: 1)
            }
            .padding(Theme.space2)
            .opacity(isFolderDropTargeted ? 1 : 0)
            .animation(.easeOut(duration: 0.12), value: isFolderDropTargeted)
            .allowsHitTesting(false)
        }
        // Files are silently ignored — `GhosttySurfaceView` already handles
        // "drop a file path at the cursor" inside a pane (M5.kk). The outline
        // lights up for any URL drag (SwiftUI's `.dropDestination` can't
        // pre-filter file-vs-folder); file drags release as no-ops.
        .dropDestination(for: URL.self) { urls, _ in
            let folders = urls.filter(isDirectory)
            guard !folders.isEmpty else { return false }
            if let delegate = NSApp.delegate as? AppDelegate {
                delegate.openWorkspaceDirectories(folders, in: store)
            } else {
                for folder in folders {
                    store.addWorkspace(workingDirectory: folder)
                }
            }
            return true
        } isTargeted: { isFolderDropTargeted = $0 }
        .sheet(item: $sheet) { current in
            switch current {
            case .createWorktree(let source):
                CreateWorktreeSheet(
                    source: source,
                    launchTemplates: AgentTemplate.visibleOrdered(model: KookySettingsModel.shared),
                    defaultLaunchTemplate: AgentTemplate.defaultLaunchTemplate(model: KookySettingsModel.shared)
                        ?? .terminal,
                    // Include every workspace's diskPath, not just worktree
                    // children — if the user opened a worktree directory as
                    // a top-level workspace (Finder drop / ⌘O), adopting it
                    // again would spawn a duplicate row pointing at the same
                    // dir. Source workspaces (the repo root) also belong in
                    // the exclusion set because the adopt picker already
                    // drops them via `sourceRootKey`; including them here is
                    // belt-and-suspenders against multi-source ⌘O scenarios.
                    alreadyAdoptedPaths: Set(
                        store.workspaces.map { $0.diskPath.standardizedFileURL.path }
                    ),
                    create: { request in
                        await store.createWorktree(source: source, request: request)
                    },
                    dismiss: {
                        store.pendingCreateWorktreeRequest = nil
                        sheet = nil
                    }
                )
            }
        }
        // Global create requests (currently the command palette). When the
        // sidebar was hidden, `onAppear` below catches the already-parked
        // request after AppDelegate makes the sidebar visible.
        .onChange(of: store.pendingCreateWorktreeRequest?.id) { _, _ in
            if let workspace = store.pendingCreateWorktreeRequest {
                sheet = .createWorktree(workspace)
            }
        }
        .onAppear {
            store.refreshWorktreeCapabilities()
            if let workspace = store.pendingCreateWorktreeRequest {
                sheet = .createWorktree(workspace)
            }
        }
    }

    @ViewBuilder
    private func brand(isCompact: Bool) -> some View {
        if isCompact {
            openWorkspaceControl()
            .padding(.top, Theme.space3)
            .padding(.bottom, Theme.space2)
        } else {
            HStack(spacing: 0) {
                Text("kooky")
                    .font(Theme.display(15, weight: .medium))
                    .foregroundStyle(Theme.chromeForeground)
                Spacer()
                openWorkspaceControl()
            }
            .padding(.horizontal, Theme.space4)
            .padding(.top, Theme.space3)
            .padding(.bottom, Theme.space2)
        }
    }

    @ViewBuilder
    private func openWorkspaceControl() -> some View {
        let delegate = NSApp.delegate as? AppDelegate
        let recentDirectories = Array((delegate?.recentWorkspaceDirectories() ?? []).prefix(8))
        if recentDirectories.isEmpty {
            HoverableIconButton(
                systemName: "plus",
                fontSize: 12,
                size: 28,
                help: "Open folder as workspace"
            ) {
                delegate?.handleOpenFolderForStore(store)
            }
        } else {
            RecentWorkspaceMenuButton(
                recentDirectories: recentDirectories,
                openDirectory: { url in
                    delegate?.openWorkspaceDirectory(url, in: store)
                },
                chooseFolder: {
                    delegate?.handleOpenFolderForStore(store)
                }
            )
        }
    }

    private func list(isCompact: Bool, proxy: ScrollViewProxy) -> some View {
        let workspaces = store.workspaces
        let parentIds = Set(workspaces.map(\.id))
        let workspaceById = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0) })
        let worktreesByParent = Dictionary(grouping: workspaces.filter { $0.worktreeParentId != nil }) { $0.worktreeParentId! }
        let canCloseOthers = workspaces.count > 1
        return ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 2) {
                if isCompact {
                    // 52pt-wide sidebar can't fit a disclosure triangle next
                    // to a 28pt icon — fall back to a flat list. The order
                    // is stable: store.workspaces already places worktrees
                    // after their source by virtue of being appended at
                    // creation time.
                    ForEach(Array(workspaces.enumerated()), id: \.element.id) { index, workspace in
                        let canCreate = store.worktreeCapability(for: workspace) == .available
                        let goToSource: (() -> Void)? = workspace.worktreeParentId
                            .flatMap { workspaceById[$0] }
                            .map { parent in { store.activateWorkspace(parent) } }
                        DraggableWorkspaceRow(
                            workspace: workspace,
                            store: store,
                            myIndex: index,
                            isCompact: isCompact,
                            canCloseOthers: canCloseOthers,
                            draggingId: $draggingWorkspaceId,
                            onCreateWorktree: canCreate ? { presentCreateWorktree(workspace) } : nil,
                            onGoToSource: goToSource
                        )
                    }
                } else {
                    // A workspace is "top-level" either because it has no
                    // parent, or because its parent is gone — defensive
                    // fallback so a bug that strands a worktree (parent
                    // closed while child kept) still surfaces the row in
                    // the sidebar instead of vanishing it entirely.
                    let topLevel = workspaces.enumerated().filter { _, ws in
                        guard let parentId = ws.worktreeParentId else { return true }
                        return !parentIds.contains(parentId)
                    }
                    ForEach(Array(topLevel), id: \.element.id) { index, workspace in
                        workspaceTree(
                            parent: workspace,
                            parentIndex: index,
                            worktrees: worktreesByParent[workspace.id] ?? [],
                            canCreate: store.worktreeCapability(for: workspace) == .available,
                            canCloseOthers: canCloseOthers
                        )
                    }
                }
            }
            .padding(.horizontal, Theme.space2)
            .padding(.vertical, Theme.space2)
        }
        // ⌘⇧R parks the active workspace on the store; reveal its row so the
        // row's own rename popover can open. onChange catches a request made
        // while the sidebar is up; onAppear catches one parked while the
        // sidebar was hidden (SidebarView mounts only after the reveal).
        .onChange(of: store.pendingRenameWorkspace?.id) { _, _ in
            revealWorkspaceForRename(using: proxy)
        }
        .onAppear { revealWorkspaceForRename(using: proxy) }
    }

    @ViewBuilder
    private func workspaceTree(
        parent: Workspace,
        parentIndex: Int,
        worktrees: [Workspace],
        canCreate: Bool,
        canCloseOthers: Bool
    ) -> some View {
        let hasWorktrees = !worktrees.isEmpty
        let isCollapsed = collapsedParents.contains(parent.id)

        DraggableWorkspaceRow(
            workspace: parent,
            store: store,
            myIndex: parentIndex,
            isCompact: false,
            canCloseOthers: canCloseOthers,
            draggingId: $draggingWorkspaceId,
            disclosure: hasWorktrees
                ? SidebarWorkspaceRow.WorktreeDisclosure(
                    isCollapsed: isCollapsed,
                    toggle: { toggleCollapsed(parent.id) }
                )
                : nil,
            onCreateWorktree: canCreate ? { presentCreateWorktree(parent) } : nil
        )

        if hasWorktrees && !isCollapsed {
            ForEach(worktrees) { worktree in
                SidebarWorkspaceRow(
                    workspace: worktree,
                    isActive: worktree.id == store.activeWorkspaceId,
                    isCompact: false,
                    canCloseOthers: canCloseOthers,
                    onActivate: { store.activateWorkspace(worktree) },
                    onClose: { store.requestCloseWorkspace(worktree) },
                    onCloseOthers: { store.closeOtherWorkspaces(keeping: worktree) },
                    onDuplicate: { store.duplicateWorkspace(worktree) },
                    onRename: { store.renameWorkspace(worktree, to: $0) },
                    onGoToSource: { store.activateWorkspace(parent) }
                )
            }
        }
    }

    private func toggleCollapsed(_ id: UUID) {
        withAnimation(.easeOut(duration: 0.12)) {
            if collapsedParents.contains(id) {
                collapsedParents.remove(id)
            } else {
                collapsedParents.insert(id)
            }
        }
    }

    /// Bring the active workspace's row into the view hierarchy so its rename
    /// popover can anchor, then hand off to the row via `renameRequested`. The
    /// row may be unmounted — nested under a collapsed worktree parent, or
    /// scrolled out of the LazyVStack's realized window. Without this the ⌘⇧R
    /// flag would sit unconsumed and then fire stale when the user later
    /// scrolled to / expanded that row.
    private func revealWorkspaceForRename(using proxy: ScrollViewProxy) {
        guard let workspace = store.pendingRenameWorkspace else { return }
        store.pendingRenameWorkspace = nil
        if let parentId = workspace.worktreeParentId, collapsedParents.contains(parentId) {
            collapsedParents.remove(parentId)
        }
        workspace.renameRequested = true
        // Defer so a just-expanded subtree is laid out before scrolling to a
        // row that may have only now been inserted.
        DispatchQueue.main.async {
            proxy.scrollTo(workspace.id, anchor: .center)
        }
    }

    private func presentCreateWorktree(_ workspace: Workspace) {
        // Single channel: parking on the store triggers the `.onChange`
        // observer that sets `sheet`. Direct row clicks and command-palette
        // / AppDelegate routes all go through here, so this stays the one
        // mechanism that opens the create sheet.
        store.pendingCreateWorktreeRequest = workspace
    }
}

private struct RecentWorkspaceMenuButton: View {
    let recentDirectories: [URL]
    let openDirectory: (URL) -> Void
    let chooseFolder: () -> Void

    @State private var isHovered = false

    var body: some View {
        Menu {
            Section("Recent Folders") {
                ForEach(recentDirectories, id: \.path) { url in
                    Button {
                        openDirectory(url)
                    } label: {
                        Label(recentWorkspaceMenuTitle(for: url), systemImage: "folder")
                    }
                }
            }
            Divider()
            Button {
                DispatchQueue.main.async {
                    chooseFolder()
                }
            } label: {
                Label("Choose Folder...", systemImage: "folder.badge.plus")
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 28, height: 28)
                .background(isHovered ? Color.white.opacity(0.12) : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Open folder as workspace")
    }

}

func recentWorkspaceMenuTitle(for url: URL) -> String {
    let name = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
    let path = (url.path as NSString).abbreviatingWithTildeInPath
    return "\(name) (\(path))"
}

/// Drag source + drop target with a direction-aware edge indicator —
/// `top` when origin is below (dragging up), `bottom` when origin is above
/// (dragging down), so the line always shows where the dropped row will land.
private struct DraggableWorkspaceRow: View {
    @Bindable var workspace: Workspace
    @Bindable var store: WorkspaceStore
    let myIndex: Int
    let isCompact: Bool
    let canCloseOthers: Bool
    @Binding var draggingId: UUID?
    /// Non-nil only for source workspaces that own at least one worktree.
    /// Worktree rows themselves render via `SidebarWorkspaceRow` directly,
    /// without this wrapper, so they don't pick up drag/drop handlers.
    var disclosure: SidebarWorkspaceRow.WorktreeDisclosure? = nil
    var onCreateWorktree: (() -> Void)? = nil
    var onGoToSource: (() -> Void)? = nil

    @State private var isTargeted = false

    var body: some View {
        let originIndex: Int? = {
            guard let id = draggingId, id != workspace.id else { return nil }
            return store.workspaces.firstIndex(where: { $0.id == id })
        }()
        let dragsDownward = (originIndex ?? Int.max) < myIndex
        let edge: Alignment = dragsDownward ? .bottom : .top
        let isSelfDrag = draggingId == workspace.id

        SidebarWorkspaceRow(
            workspace: workspace,
            isActive: workspace.id == store.activeWorkspaceId,
            isCompact: isCompact,
            canCloseOthers: canCloseOthers,
            onActivate: { store.activateWorkspace(workspace) },
            onClose: { store.requestCloseWorkspace(workspace) },
            closeConfirmation: closeConfirmation,
            onConfirmedClose: canCloseInline ? { store.closeWorkspace(workspace) } : nil,
            onCloseOthers: { store.closeOtherWorkspaces(keeping: workspace) },
            onDuplicate: { store.duplicateWorkspace(workspace) },
            onRename: { store.renameWorkspace(workspace, to: $0) },
            disclosure: disclosure,
            onCreateWorktree: onCreateWorktree,
            onGoToSource: onGoToSource
        )
        .dropIndicator(active: isTargeted && !isSelfDrag, on: edge)
        .onDrag {
            draggingId = workspace.id
            return NSItemProvider(object: workspace.id.uuidString as NSString)
        }
        .dropDestination(for: String.self) { dropped, _ in
            defer { draggingId = nil }
            guard let id = dropped.first.flatMap(UUID.init),
                  let from = store.workspaces.firstIndex(where: { $0.id == id })
            else { return false }
            withAnimation(.easeInOut(duration: 0.18)) {
                store.moveWorkspace(from: from, to: myIndex)
            }
            return true
        } isTargeted: { isTargeted = $0 }
    }

    private var closeConfirmation: CloseConfirmation? {
        guard canCloseInline else { return nil }
        return CloseConfirmation(title: "Close workspace?", confirmLabel: "close")
    }

    private var canCloseInline: Bool {
        workspace.worktreeParentId == nil
            && !store.workspaces.contains { $0.worktreeParentId == workspace.id }
    }
}
