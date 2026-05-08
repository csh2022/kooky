import SwiftUI

struct SidebarWorkspaceRow: View {
    let workspace: Workspace
    let isActive: Bool
    let onActivate: () -> Void
    let onClose: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: Theme.space2) {
            agentIcons
            VStack(alignment: .leading, spacing: 2) {
                Text(workspace.title)
                    .font(Theme.display(13, weight: .regular))
                    .foregroundStyle(isActive ? Theme.chromeForeground : Theme.chromeForeground.opacity(0.78))
                    .lineLimit(1)
                Text((workspace.workingDirectory.path as NSString).abbreviatingWithTildeInPath)
                    .font(Theme.mono(10.5))
                    .foregroundStyle(Theme.chromeMuted)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 0)
            // Activity dot lives at the trailing edge — visible at all times
            // when not idle, eats the close-button slot only on hover.
            ZStack {
                if let color = activityDotColor {
                    Circle().fill(color).frame(width: 6, height: 6)
                        .opacity(isHovered ? 0 : 1)
                }
                HoverableIconButton(
                    systemName: "xmark",
                    fontSize: 9,
                    size: 20,
                    help: "Close workspace",
                    action: onClose
                )
                .opacity(isHovered ? 1 : 0)
                .allowsHitTesting(isHovered)
            }
            .frame(minWidth: 20, alignment: .trailing)
        }
        .padding(.horizontal, Theme.space3)
        .padding(.vertical, 11)
        .background(rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture(perform: onActivate)
        .onHover { isHovered = $0 }
        .help(workspace.workingDirectory.path)
    }

    @ViewBuilder
    private var agentIcons: some View {
        // Single leading mark: first non-terminal agent's brand icon, or the
        // Terminal SF Symbol when the workspace only runs plain shells.
        // Multi-agent workspaces get a `+N` badge showing the additional
        // distinct agents — first agent stays the dominant mark.
        let agents = workspace.distinctAgents
        if let agent = agents.first {
            ZStack(alignment: .bottomTrailing) {
                AgentIconView(asset: agent.iconAsset, fallbackSymbol: agent.symbol, size: 20)
                if agents.count > 1 {
                    Text("+\(agents.count - 1)")
                        .font(Theme.mono(9))
                        .foregroundStyle(Theme.chromeBackground)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 0.5)
                        .background(Capsule().fill(Theme.chromeForeground.opacity(0.92)))
                        .offset(x: 6, y: 4)
                }
            }
            .opacity(isActive ? 1 : 0.85)
        } else {
            Image(systemName: AgentTemplate.terminal.symbol)
                .font(.system(size: 16))
                .foregroundStyle(Theme.chromeMuted)
                .frame(width: 20, height: 20)
        }
    }

    private var activityDotColor: Color? {
        // Hue chosen for at-a-glance read: cool blue == "thinking", warm
        // amber == "needs you". Idle stays unmarked so the row reads quiet.
        switch workspace.activityState {
        case .idle: return nil
        case .running: return Color(.sRGB, red: 0.41, green: 0.69, blue: 0.86, opacity: 1)
        case .attention: return Color(.sRGB, red: 0.91, green: 0.69, blue: 0.40, opacity: 1)
        }
    }

    private var rowBackground: Color {
        if isActive { return Theme.chromeActive }
        if isHovered { return Theme.chromeHover }
        return .clear
    }
}
