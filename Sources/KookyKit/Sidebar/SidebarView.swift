import SwiftUI

/// Bundles every modal sheet the sidebar can show so they share one
/// `.sheet(item:)` modifier. `.sheet(isPresented:)` per state would race
/// when switching directly between modes (create → confirm-remove).
private enum SidebarSheet: Identifiable {
    case createWorktree(Workspace)
    case confirmRemoveWorktree(Workspace)
    case confirmCloseOthers(WorkspaceStore.BulkRemovalRequest)
    case confirmCloseSource(WorkspaceStore.CloseSourceRequest)

    var id: String {
        switch self {
        case .createWorktree(let ws): return "create-\(ws.id.uuidString)"
        case .confirmRemoveWorktree(let ws): return "remove-\(ws.id.uuidString)"
        case .confirmCloseOthers(let req): return "close-others-\(req.keeping.id.uuidString)"
        case .confirmCloseSource(let req): return "close-source-\(req.source.id.uuidString)"
        }
    }
}

struct SidebarView: View {
    static let fullWidth: CGFloat = 220
    static let compactWidth: CGFloat = 52
    /// Indent for worktree rows under their source workspace.
    static let worktreeIndent: CGFloat = 16

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
    /// Active modal sheet (create worktree / confirm-remove worktree).
    /// Nil = no sheet. Set by row callbacks and an onChange observer that
    /// watches `store.pendingRemovalRequest` for ⌘⇧W routed via AppDelegate.
    @State private var sheet: SidebarSheet?

    var body: some View {
        let isCompact = store.sidebarMode == .compact
        VStack(spacing: 0) {
            brand(isCompact: isCompact)
            list(isCompact: isCompact)
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
            for folder in folders {
                store.addWorkspace(workingDirectory: folder)
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
                    create: { request in
                        await store.createWorktree(source: source, request: request)
                    },
                    dismiss: { sheet = nil }
                )
            case .confirmRemoveWorktree(let workspace):
                ConfirmRemoveWorktreeSheet(
                    workspace: workspace,
                    confirm: {
                        if let message = await store.removeWorktreeDirectory(workspace) {
                            return .failure(message)
                        }
                        store.closeWorkspace(workspace)
                        store.pendingRemovalRequest = nil
                        return .success
                    },
                    dismiss: {
                        store.pendingRemovalRequest = nil
                        sheet = nil
                    }
                )
            case .confirmCloseOthers(let request):
                ConfirmBulkCloseSheet(
                    statusLabel: "CLOSE-OTHERS",
                    headlineText: "keeping \(request.keeping.title)",
                    subtitleText: bulkSubtitle(
                        closingCount: request.others.count,
                        worktreeCount: request.worktreeOthers.count
                    ),
                    worktreesAmong: request.worktreeOthers,
                    confirmButtonTitle: "close",
                    workingButtonTitle: "closing…",
                    confirm: {
                        if let message = await store.performCloseOthers(request) {
                            return .failure(message)
                        }
                        return .success
                    },
                    dismiss: {
                        store.pendingCloseOthersRequest = nil
                        sheet = nil
                    }
                )
            case .confirmCloseSource(let request):
                ConfirmBulkCloseSheet(
                    statusLabel: "CLOSE-WORKSPACE",
                    headlineText: "closing \(request.source.title)",
                    subtitleText: bulkSubtitle(
                        closingCount: request.worktrees.count + 1,
                        worktreeCount: request.worktrees.count
                    ),
                    worktreesAmong: request.worktrees,
                    confirmButtonTitle: "close",
                    workingButtonTitle: "closing…",
                    confirm: {
                        if let message = await store.performCloseSource(request) {
                            return .failure(message)
                        }
                        return .success
                    },
                    dismiss: {
                        store.pendingCloseSourceRequest = nil
                        sheet = nil
                    }
                )
            }
        }
        // ⌘⇧W routes through AppDelegate → store.requestCloseWorkspace,
        // which parks worktree workspaces in `pendingRemovalRequest` for
        // the sidebar to pop the confirm sheet on. Identity-keyed so the
        // observer only fires on a fresh request, not internal renames.
        .onChange(of: store.pendingRemovalRequest?.id) { _, _ in
            if let workspace = store.pendingRemovalRequest {
                sheet = .confirmRemoveWorktree(workspace)
            }
        }
        // Bulk close-others request — keyed off keeping.id since the
        // others list can vary in length but each request is anchored
        // on its keeping workspace.
        .onChange(of: store.pendingCloseOthersRequest?.keeping.id) { _, _ in
            if let request = store.pendingCloseOthersRequest {
                sheet = .confirmCloseOthers(request)
            }
        }
        // Close-source-with-worktrees request — keyed off source.id; the
        // store parks it when ⌘⇧W / × on a top-level workspace would
        // strand its worktrees.
        .onChange(of: store.pendingCloseSourceRequest?.source.id) { _, _ in
            if let request = store.pendingCloseSourceRequest {
                sheet = .confirmCloseSource(request)
            }
        }
    }

    /// Shared subtitle string between the two bulk-close flows — folds
    /// pluralisation into one place so the count never reads as
    /// "1 workspaces" or "1 worktrees".
    private func bulkSubtitle(closingCount: Int, worktreeCount: Int) -> String {
        let workspaceWord = closingCount == 1 ? "workspace" : "workspaces"
        let worktreeWord = worktreeCount == 1 ? "worktree" : "worktrees"
        return "\(closingCount) \(workspaceWord) will close · \(worktreeCount) \(worktreeWord)"
    }

    /// True when `workspace` is a top-level source workspace *and* its
    /// cwd is inside a git repo. Worktree rows are excluded (worktree
    /// nesting isn't supported); non-git workspaces (e.g. `~/Downloads`
    /// opened as a workspace) hide the menu item so users never see an
    /// option that can only error.
    private func canCreateWorktree(from workspace: Workspace) -> Bool {
        guard workspace.worktreeParentId == nil else { return false }
        return GitWatcher.findGitDir(near: workspace.workingDirectory) != nil
    }

    @ViewBuilder
    private func brand(isCompact: Bool) -> some View {
        if isCompact {
            HoverableIconButton(
                systemName: "plus",
                fontSize: 12,
                size: 28,
                help: "New workspace"
            ) {
                store.addWorkspace()
            }
            .padding(.top, Theme.space3)
            .padding(.bottom, Theme.space2)
        } else {
            HStack(spacing: 0) {
                Text("kooky")
                    .font(Theme.display(15, weight: .medium))
                    .foregroundStyle(Theme.chromeForeground)
                Spacer()
                HoverableIconButton(
                    systemName: "plus",
                    fontSize: 12,
                    size: 26,
                    help: "New workspace"
                ) {
                    store.addWorkspace()
                }
            }
            .padding(.horizontal, Theme.space4)
            .padding(.top, Theme.space3)
            .padding(.bottom, Theme.space2)
        }
    }

    private func list(isCompact: Bool) -> some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 2) {
                if isCompact {
                    // 52pt-wide sidebar can't fit a disclosure triangle next
                    // to a 28pt icon — fall back to a flat list. The order
                    // is stable: store.workspaces already places worktrees
                    // after their source by virtue of being appended at
                    // creation time.
                    ForEach(Array(store.workspaces.enumerated()), id: \.element.id) { index, workspace in
                        DraggableWorkspaceRow(
                            workspace: workspace,
                            store: store,
                            myIndex: index,
                            isCompact: isCompact,
                            draggingId: $draggingWorkspaceId,
                            onCreateWorktree: canCreateWorktree(from: workspace)
                                ? { sheet = .createWorktree(workspace) }
                                : nil
                        )
                    }
                } else {
                    // A workspace is "top-level" either because it has no
                    // parent, or because its parent is gone — defensive
                    // fallback so a bug that strands a worktree (parent
                    // closed while child kept) still surfaces the row in
                    // the sidebar instead of vanishing it entirely.
                    let parentIds = Set(store.workspaces.map(\.id))
                    let topLevel = store.workspaces.enumerated().filter { _, ws in
                        guard let parentId = ws.worktreeParentId else { return true }
                        return !parentIds.contains(parentId)
                    }
                    ForEach(Array(topLevel), id: \.element.id) { index, workspace in
                        workspaceTree(parent: workspace, parentIndex: index)
                    }
                }
            }
            .padding(.horizontal, Theme.space2)
            .padding(.vertical, Theme.space2)
        }
    }

    @ViewBuilder
    private func workspaceTree(parent: Workspace, parentIndex: Int) -> some View {
        let worktrees = store.workspaces.filter { $0.worktreeParentId == parent.id }
        let hasWorktrees = !worktrees.isEmpty
        let isCollapsed = collapsedParents.contains(parent.id)

        DraggableWorkspaceRow(
            workspace: parent,
            store: store,
            myIndex: parentIndex,
            isCompact: false,
            draggingId: $draggingWorkspaceId,
            disclosure: hasWorktrees
                ? SidebarWorkspaceRow.WorktreeDisclosure(
                    isCollapsed: isCollapsed,
                    toggle: { toggleCollapsed(parent.id) }
                )
                : nil,
            onCreateWorktree: canCreateWorktree(from: parent)
                ? { sheet = .createWorktree(parent) }
                : nil
        )

        if hasWorktrees && !isCollapsed {
            ForEach(worktrees) { worktree in
                SidebarWorkspaceRow(
                    workspace: worktree,
                    isActive: worktree.id == store.activeWorkspaceId,
                    isCompact: false,
                    canCloseOthers: store.workspaces.count > 1,
                    onActivate: { store.activateWorkspace(worktree) },
                    onClose: { store.requestCloseWorkspace(worktree) },
                    onCloseOthers: { store.closeOtherWorkspaces(keeping: worktree) },
                    onDuplicate: { store.duplicateWorkspace(worktree) },
                    onRename: { store.renameWorkspace(worktree, to: $0) }
                )
                .padding(.leading, Self.worktreeIndent)
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
}

/// Drag source + drop target with a direction-aware edge indicator —
/// `top` when origin is below (dragging up), `bottom` when origin is above
/// (dragging down), so the line always shows where the dropped row will land.
private struct DraggableWorkspaceRow: View {
    @Bindable var workspace: Workspace
    @Bindable var store: WorkspaceStore
    let myIndex: Int
    let isCompact: Bool
    @Binding var draggingId: UUID?
    /// Non-nil only for source workspaces that own at least one worktree.
    /// Worktree rows themselves render via `SidebarWorkspaceRow` directly,
    /// without this wrapper, so they don't pick up drag/drop handlers.
    var disclosure: SidebarWorkspaceRow.WorktreeDisclosure? = nil
    var onCreateWorktree: (() -> Void)? = nil

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
            canCloseOthers: store.workspaces.count > 1,
            onActivate: { store.activateWorkspace(workspace) },
            onClose: { store.requestCloseWorkspace(workspace) },
            onCloseOthers: { store.closeOtherWorkspaces(keeping: workspace) },
            onDuplicate: { store.duplicateWorkspace(workspace) },
            onRename: { store.renameWorkspace(workspace, to: $0) },
            disclosure: disclosure,
            onCreateWorktree: onCreateWorktree
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
}
