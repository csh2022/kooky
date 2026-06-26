import SwiftUI

/// Small confirmation sheet for close actions that only affect kooky's app
/// state: ordinary workspaces and sessions. Worktree disk/branch deletion
/// keeps using the specialized worktree sheets with an explicit checkbox.
struct ConfirmCloseSheet: View {
    let statusLabel: String
    let headlineText: String
    let subtitleText: String
    let confirmLabel: String
    let confirm: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusBadge
                .padding(.bottom, 18)

            headline
            subtitle
                .padding(.top, 6)

            Rectangle()
                .fill(Theme.chromeHairline)
                .frame(width: 32, height: 1)
                .padding(.vertical, 22)

            HStack(spacing: 10) {
                Spacer()
                BracketButton("cancel") { dismiss() }
                BracketButton(confirmLabel) {
                    confirm()
                    dismiss()
                }
            }
        }
        .padding(.vertical, 22)
        .padding(.horizontal, 28)
        .frame(width: 460, alignment: .topLeading)
        .background(Theme.chromeBackground)
        .preferredColorScheme(Theme.chromeColorScheme)
    }

    private var statusBadge: some View {
        Text(statusLabel)
            .font(Theme.mono(10, weight: .medium))
            .tracking(1.6)
            .foregroundStyle(Theme.chromeMuted.opacity(0.85))
    }

    private var headline: some View {
        Text(headlineText)
            .font(Theme.display(20, weight: .medium))
            .foregroundStyle(Theme.chromeForeground)
            .lineLimit(2)
    }

    private var subtitle: some View {
        Text(subtitleText)
            .font(Theme.mono(11.5))
            .foregroundStyle(Theme.chromeMuted)
            .fixedSize(horizontal: false, vertical: true)
    }
}
