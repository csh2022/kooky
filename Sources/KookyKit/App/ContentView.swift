import AppKit
import SwiftUI

private enum ContentConfirmationSheet: Identifiable {
    case closeWorkspace(WorkspaceStore.CloseWorkspaceRequest)
    case closeSessions(WorkspaceStore.CloseSessionsRequest)
    case removeWorktree(Workspace)
    case closeOthers(WorkspaceStore.BulkRemovalRequest)
    case closeSource(WorkspaceStore.CloseSourceRequest)

    var id: String {
        switch self {
        case .closeWorkspace(let request): return "close-workspace-\(request.id.uuidString)"
        case .closeSessions(let request): return "close-sessions-\(request.id.uuidString)"
        case .removeWorktree(let workspace): return "remove-worktree-\(workspace.id.uuidString)"
        case .closeOthers(let request): return "close-others-\(request.id.uuidString)"
        case .closeSource(let request): return "close-source-\(request.id.uuidString)"
        }
    }
}

struct ContentView: View {
    private enum TopStripLayout {
        static let normalLeadingClearance: CGFloat = 82
        static let fullScreenLeadingClearance: CGFloat = 16
        static let searchSideReserve: CGFloat = normalLeadingClearance + 28
    }

    @Bindable var store: WorkspaceStore
    @State private var isWindowFullScreen = false
    @State private var confirmationSheet: ContentConfirmationSheet?

    var body: some View {
        VStack(spacing: 0) {
            topStrip
            Rectangle().fill(Theme.chromeHairline).frame(height: 1)
            HStack(spacing: 0) {
                if store.sidebarMode != .hidden {
                    SidebarView(store: store)
                    Rectangle().fill(Theme.chromeHairline).frame(width: 1)
                }
                mainPane
                    .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                    .layoutPriority(1)
                    .clipped()
                if store.rightSidebarMode != .hidden {
                    Rectangle().fill(Theme.chromeHairline).frame(width: 1)
                    AgentOverviewSidebar(mode: store.rightSidebarMode)
                }
            }
        }
        .background(chromeBackground)
        .preferredColorScheme(Theme.chromeColorScheme)
        .ignoresSafeArea(.all)
        .background(WindowFullScreenObserver(isFullScreen: $isWindowFullScreen))
        .sheet(item: $confirmationSheet) { current in
            switch current {
            case .closeWorkspace(let request):
                ConfirmCloseSheet(
                    statusLabel: "CLOSE-WORKSPACE",
                    headlineText: request.workspace.title,
                    subtitleText: closeWorkspaceSubtitle(for: request.workspace),
                    confirmLabel: "close",
                    confirm: {
                        store.performCloseWorkspace(request)
                    },
                    dismiss: {
                        store.pendingCloseWorkspaceRequest = nil
                        confirmationSheet = nil
                    }
                )
            case .closeSessions(let request):
                ConfirmCloseSheet(
                    statusLabel: request.isSingleSession ? "CLOSE-SESSION" : "CLOSE-SESSIONS",
                    headlineText: closeSessionsHeadline(for: request),
                    subtitleText: closeSessionsSubtitle(for: request),
                    confirmLabel: request.isSingleSession ? "close session" : "close sessions",
                    confirm: {
                        store.performCloseSessions(request)
                    },
                    dismiss: {
                        store.pendingCloseSessionsRequest = nil
                        confirmationSheet = nil
                    }
                )
            case .removeWorktree(let workspace):
                ConfirmRemoveWorktreeSheet(
                    workspace: workspace,
                    confirm: { alsoDelete in
                        if alsoDelete {
                            if let message = await store.removeWorktreeDirectory(workspace) {
                                return .failure(message)
                            }
                        }
                        store.closeWorkspace(workspace)
                        store.pendingRemovalRequest = nil
                        return .success
                    },
                    dismiss: {
                        store.pendingRemovalRequest = nil
                        confirmationSheet = nil
                    }
                )
            case .closeOthers(let request):
                ConfirmBulkCloseSheet(
                    statusLabel: "CLOSE-OTHERS",
                    headlineText: "keeping \(request.keeping.title)",
                    subtitleText: bulkSubtitle(
                        closingCount: request.others.count,
                        worktreeCount: request.worktreeOthers.count
                    ),
                    worktreesAmong: request.worktreeOthers,
                    confirm: { alsoDelete in
                        if let message = await store.performCloseOthers(request, alsoDelete: alsoDelete) {
                            return .failure(message)
                        }
                        return .success
                    },
                    dismiss: {
                        store.pendingCloseOthersRequest = nil
                        confirmationSheet = nil
                    }
                )
            case .closeSource(let request):
                ConfirmBulkCloseSheet(
                    statusLabel: "CLOSE-WORKSPACE",
                    headlineText: "closing \(request.source.title)",
                    subtitleText: bulkSubtitle(
                        closingCount: request.worktrees.count + 1,
                        worktreeCount: request.worktrees.count
                    ),
                    worktreesAmong: request.worktrees,
                    confirm: { alsoDelete in
                        if let message = await store.performCloseSource(request, alsoDelete: alsoDelete) {
                            return .failure(message)
                        }
                        return .success
                    },
                    dismiss: {
                        store.pendingCloseSourceRequest = nil
                        confirmationSheet = nil
                    }
                )
            }
        }
        .onChange(of: store.pendingCloseWorkspaceRequest?.id) { _, _ in
            presentPendingConfirmation()
        }
        .onChange(of: store.pendingCloseSessionsRequest?.id) { _, _ in
            presentPendingConfirmation()
        }
        .onChange(of: store.pendingRemovalRequest?.id) { _, _ in
            presentPendingConfirmation()
        }
        .onChange(of: store.pendingCloseOthersRequest?.id) { _, _ in
            presentPendingConfirmation()
        }
        .onChange(of: store.pendingCloseSourceRequest?.id) { _, _ in
            presentPendingConfirmation()
        }
        .onAppear {
            presentPendingConfirmation()
        }
    }

    /// Top 32pt strip. `window.isMovable = false` is set globally, so the
    /// full-strip `WindowDragHandle` background is the only place AppKit
    /// allows window dragging. The search pill is centered against the whole
    /// strip, not the space between controls; otherwise the full-screen
    /// sidebar-toggle clearance would also tug the search pill left.
    private var topStrip: some View {
        ZStack {
            WindowDragHandle()
            centeredSearchPill
            HStack(spacing: 0) {
                leadingControls
                Spacer(minLength: 0)
                trailingControls
            }
        }
        .frame(height: 32)
    }

    private var leadingControls: some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: isWindowFullScreen ? TopStripLayout.fullScreenLeadingClearance : TopStripLayout.normalLeadingClearance)
                .allowsHitTesting(false)
            HoverableIconButton(
                systemName: "sidebar.left",
                fontSize: 12,
                size: 28,
                help: sidebarTooltip
            ) {
                withAnimation(Theme.chromeTransition) {
                    store.setSidebarMode(store.sidebarMode.next)
                }
            }
        }
    }

    private var trailingControls: some View {
        HStack(spacing: 0) {
            HoverableIconButton(
                systemName: "square.grid.2x2",
                fontSize: 12,
                size: 28,
                help: "Agent Panel"
            ) {
                withAnimation(Theme.chromeTransition) {
                    store.setRightSidebarMode(store.rightSidebarMode.next)
                }
            }
            HoverableIconButton(
                systemName: "globe",
                fontSize: 12,
                size: 28,
                help: "Browser Panel"
            ) {
                withAnimation(Theme.chromeTransition) {
                    _ = store.openBrowserSplit()
                }
            }
            InboxBell()
                .padding(.trailing, 8)
        }
    }

    @ViewBuilder
    private var centeredSearchPill: some View {
        if KookySettingsModel.shared.showSearchPill {
            ViewThatFits(in: .horizontal) {
                SearchTriggerPill {
                    NSApp.sendAction(#selector(AppDelegate.handleQuickOpen), to: nil, from: nil)
                }
                .padding(.horizontal, TopStripLayout.searchSideReserve)
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private var mainPane: some View {
        if let workspace = store.active {
            PaneTreeView(node: workspace.root, workspace: workspace, store: store)
                .id(workspace.id)
        } else {
            Color.clear
        }
    }

    private var chromeBackground: Color {
        let color = store.active?.activeSession?.engine.backgroundColor ?? Theme.terminalSurface
        return Color(nsColor: color)
    }

    private var sidebarTooltip: String {
        switch store.sidebarMode {
        case .full: return "Compact sidebar"
        case .compact: return "Hide sidebar"
        case .hidden: return "Show sidebar"
        }
    }

    private func presentPendingConfirmation() {
        if let request = store.pendingCloseWorkspaceRequest {
            confirmationSheet = .closeWorkspace(request)
        } else if let request = store.pendingCloseSessionsRequest {
            confirmationSheet = .closeSessions(request)
        } else if let workspace = store.pendingRemovalRequest {
            confirmationSheet = .removeWorktree(workspace)
        } else if let request = store.pendingCloseOthersRequest {
            confirmationSheet = .closeOthers(request)
        } else if let request = store.pendingCloseSourceRequest {
            confirmationSheet = .closeSource(request)
        }
    }

    private func closeWorkspaceSubtitle(for workspace: Workspace) -> String {
        let path = (workspace.diskPath.path as NSString).abbreviatingWithTildeInPath
        let sessionCount = workspace.root.allPanes.reduce(0) { $0 + $1.tabs.count }
        let sessionWord = sessionCount == 1 ? "session" : "sessions"
        return "\(path)\n\(sessionCount) \(sessionWord) will close. Files on disk stay untouched."
    }

    private func closeSessionsHeadline(for request: WorkspaceStore.CloseSessionsRequest) -> String {
        if request.isSingleSession, let session = request.sessions.first {
            return session.title
        }
        return "\(request.sessions.count) sessions"
    }

    private func closeSessionsSubtitle(for request: WorkspaceStore.CloseSessionsRequest) -> String {
        if request.isSingleSession, let session = request.sessions.first {
            let path = (session.currentDirectory.path as NSString).abbreviatingWithTildeInPath
            return "\(path)\nThe running process in this session will terminate."
        }
        return "\(request.sessions.count) sessions in \(request.workspace.title) will close. Running processes will terminate."
    }

    private func bulkSubtitle(closingCount: Int, worktreeCount: Int) -> String {
        let workspaceWord = closingCount == 1 ? "workspace" : "workspaces"
        guard worktreeCount > 0 else { return "\(closingCount) \(workspaceWord) will close" }
        let worktreeWord = worktreeCount == 1 ? "worktree" : "worktrees"
        return "\(closingCount) \(workspaceWord) will close · \(worktreeCount) \(worktreeWord)"
    }

}

private struct WindowFullScreenObserver: NSViewRepresentable {
    @Binding var isFullScreen: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            context.coordinator.attach(to: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            context.coordinator.attach(to: nsView.window)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(isFullScreen: $isFullScreen)
    }

    @MainActor
    final class Coordinator: NSObject {
        private let isFullScreen: Binding<Bool>
        private weak var window: NSWindow?

        init(isFullScreen: Binding<Bool>) {
            self.isFullScreen = isFullScreen
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func attach(to window: NSWindow?) {
            guard self.window !== window else {
                update(from: window)
                return
            }
            NotificationCenter.default.removeObserver(self)
            self.window = window
            update(from: window)
            guard let window else { return }
            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(didEnterFullScreen), name: NSWindow.didEnterFullScreenNotification, object: window)
            center.addObserver(self, selector: #selector(didExitFullScreen), name: NSWindow.didExitFullScreenNotification, object: window)
        }

        @objc private func didEnterFullScreen() {
            isFullScreen.wrappedValue = true
        }

        @objc private func didExitFullScreen() {
            isFullScreen.wrappedValue = false
        }

        private func update(from window: NSWindow?) {
            isFullScreen.wrappedValue = window?.styleMask.contains(.fullScreen) == true
        }
    }
}
