import AppKit
import SwiftUI

struct ContentView: View {
    @Bindable var store: WorkspaceStore
    @State private var isWindowFullScreen = false

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
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    }

    /// Top 32pt strip. `window.isMovable = false` is set globally, so the
    /// `WindowDragHandle` background is the only place AppKit allows
    /// window dragging. The `SearchTriggerPill` lives in an *inner* ZStack
    /// scoped to the drag-handle area (not the whole strip) so it centers
    /// in the available space and can't overlap the sidebar toggle when
    /// the window is dragged narrow. `ViewThatFits` drops the pill
    /// entirely once even the inner area can't hold its 280pt frame —
    /// `⌘P` + the File menu still reach the palette.
    private var topStrip: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: isWindowFullScreen ? Theme.space4 : 82).allowsHitTesting(false)
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
            WindowDragHandle()
                .overlay {
                    if KookySettingsModel.shared.showSearchPill {
                        ViewThatFits(in: .horizontal) {
                            SearchTriggerPill {
                                NSApp.sendAction(#selector(AppDelegate.handleQuickOpen), to: nil, from: nil)
                            }
                            EmptyView()
                        }
                    }
                }
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
            InboxBell()
                .padding(.trailing, 8)
        }
        .frame(height: 32)
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
