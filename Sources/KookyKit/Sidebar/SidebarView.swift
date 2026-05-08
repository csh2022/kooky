import SwiftUI

struct SidebarView: View {
    static let width: CGFloat = 220

    @Bindable var store: WorkspaceStore

    var body: some View {
        VStack(spacing: 0) {
            header
            list
            Spacer(minLength: 0)
        }
        .frame(width: Self.width)
        .background(Theme.chromeBackground)
    }

    private var header: some View {
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
        // Top padding clears the traffic-light area (window is full-content;
        // there's no real title bar to push us down).
        .padding(.top, 32)
        .padding(.bottom, Theme.space3)
    }

    private var list: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 2) {
                ForEach(store.workspaces) { workspace in
                    SidebarWorkspaceRow(
                        workspace: workspace,
                        isActive: workspace.id == store.activeWorkspaceId,
                        onActivate: { store.activateWorkspace(workspace) },
                        onClose: { store.closeWorkspace(workspace) }
                    )
                }
            }
            .padding(.horizontal, Theme.space2)
            .padding(.bottom, Theme.space2)
        }
    }
}
