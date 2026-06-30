import SwiftUI

struct CloseConfirmation {
    let title: String
    let confirmLabel: String
}

/// Lightweight confirmation anchored to the close button. It is intentionally
/// terse: ordinary tab/workspace closes only need a mis-click guard, while
/// worktree disk/branch removal keeps using the larger sheet.
struct ConfirmClosePopover: View {
    let confirmation: CloseConfirmation
    let confirm: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(confirmation.title)
                .font(Theme.display(13.5, weight: .medium))
                .foregroundStyle(Theme.chromeForeground)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                BracketButton("cancel", tone: .secondary) {
                    dismiss()
                }
                BracketButton(confirmation.confirmLabel, tone: .destructive) {
                    confirm()
                    dismiss()
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .frame(width: 220, alignment: .topLeading)
        .background(Theme.chromeBackground)
        .preferredColorScheme(Theme.chromeColorScheme)
    }
}
