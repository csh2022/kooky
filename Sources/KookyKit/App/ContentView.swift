import AppKit
import SwiftUI

struct ContentView: View {
    let store: WorkspaceStore

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(store: store)
            Rectangle().fill(Theme.chromeHairline).frame(width: 1)
            mainPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(chromeBackground)
        .ignoresSafeArea(.all)
        .onChange(of: store.workspaces.isEmpty) { _, isEmpty in
            // Closing the last workspace closes the window — matches Warp/Ghostty.
            // applicationShouldTerminateAfterLastWindowClosed then quits the app.
            if isEmpty { NSApplication.shared.keyWindow?.close() }
        }
    }

    @ViewBuilder
    private var mainPane: some View {
        if let workspace = store.active {
            VStack(spacing: 0) {
                TabBarView(
                    workspace: workspace,
                    onActivateTab: { store.activateTab($0, in: workspace) },
                    onAddTab: { template in store.addTab(in: workspace, template: template) },
                    onCloseTab: { store.closeTab($0, in: workspace) }
                )
                Rectangle().fill(Theme.chromeHairline).frame(height: 1)
                if let tab = workspace.activeTab {
                    TerminalView(engine: tab.engine)
                        // .id forces SwiftUI to rebuild the NSViewRepresentable
                        // when the active tab changes, so libghostty receives a
                        // fresh viewDidMoveToWindow on the swapped-in surface.
                        .id(tab.id)
                        .padding(12)
                } else {
                    Color.clear
                }
            }
        } else {
            Color.clear
        }
    }

    private var chromeBackground: Color {
        let color = store.active?.activeTab?.engine.backgroundColor ?? Theme.terminalSurface
        return Color(nsColor: color)
    }
}
