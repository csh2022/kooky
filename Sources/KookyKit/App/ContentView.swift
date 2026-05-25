import AppKit
import SwiftUI

struct ContentView: View {
    @Bindable var store: WorkspaceStore

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
            }
        }
        .background(chromeBackground)
        .ignoresSafeArea(.all)
    }

    /// Top 32pt strip. `window.isMovable = false` is set globally, so the
    /// `WindowDragHandle` background is the only place AppKit allows
    /// window dragging. The centered `SearchTriggerPill` sits *above* the
    /// drag handle in the ZStack so clicks on the pill open the palette
    /// while drags on the surrounding empty area still move the window.
    private var topStrip: some View {
        ZStack {
            HStack(spacing: 0) {
                Color.clear.frame(width: 82).allowsHitTesting(false)
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
            }
            SearchTriggerPill {
                NSApp.sendAction(#selector(AppDelegate.handleQuickOpen), to: nil, from: nil)
            }
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
