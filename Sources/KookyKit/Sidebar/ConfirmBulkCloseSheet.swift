import AppKit
import SwiftUI

/// Brutalist bulk-close confirm — used by both "Close Other Workspaces"
/// and "close source workspace that has worktrees". The two flows share
/// the same shape: a list of worktrees about to lose their directories
/// plus cancel/close buttons.
/// Caller supplies the labels so the sheet stays content-agnostic.
struct ConfirmBulkCloseSheet: View {
    enum Outcome: Equatable {
        case success
        case failure(String)
    }

    let statusLabel: String
    let headlineText: String
    let subtitleText: String
    let worktreesAmong: [Workspace]
    let confirmButtonTitle: String
    let workingButtonTitle: String
    /// Always deletes the listed worktree directories — the sidebar = disk
    /// invariant means there's no "keep dir" path. Caller closes the
    /// workspaces and clears the pending request before resolving.
    let confirm: @MainActor () async -> Outcome
    let dismiss: () -> Void

    @State private var isWorking: Bool = false
    @State private var errorMessage: String?

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

            worktreeList
                .padding(.bottom, 14)

            warningRow

            if let errorMessage {
                Text(errorMessage)
                    .font(Theme.mono(11.5))
                    .foregroundStyle(Theme.activityFailure.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 14)
            }

            HStack(spacing: 10) {
                Spacer()
                BracketButton("cancel") { dismiss() }
                    .disabled(isWorking)
                    .opacity(isWorking ? 0.4 : 1)
                BracketButton(isWorking ? workingButtonTitle : confirmButtonTitle) { submit() }
                    .disabled(isWorking)
                    .opacity(isWorking ? 0.4 : 1)
            }
            .padding(.top, 22)
        }
        .padding(.vertical, 22)
        .padding(.horizontal, 28)
        .frame(width: 480, alignment: .topLeading)
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
    }

    private var subtitle: some View {
        Text(subtitleText)
            .font(Theme.mono(11.5))
            .foregroundStyle(Theme.chromeMuted)
    }

    private var worktreeList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(worktreesAmong) { worktree in
                HStack(spacing: 8) {
                    Text("•")
                        .font(Theme.mono(11.5))
                        .foregroundStyle(Theme.chromeMuted)
                    Text(worktree.title)
                        .font(Theme.mono(11.5))
                        .foregroundStyle(Theme.chromeForeground)
                }
            }
        }
    }

    private var warningRow: some View {
        let count = worktreesAmong.count
        let text = count == 1
            ? "The worktree directory will be deleted. Uncommitted changes will be lost."
            : "The \(count) worktree directories will be deleted. Uncommitted changes will be lost."
        return Text(text)
            .font(Theme.mono(11.5))
            .foregroundStyle(Theme.chromeMuted)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func submit() {
        isWorking = true
        errorMessage = nil
        Task {
            let outcome = await confirm()
            switch outcome {
            case .success:
                dismiss()
            case .failure(let message):
                isWorking = false
                errorMessage = message
            }
        }
    }
}
