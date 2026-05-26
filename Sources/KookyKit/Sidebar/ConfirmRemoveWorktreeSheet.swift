import AppKit
import SwiftUI

/// Brutalist confirm sheet for closing a worktree workspace. Same visual
/// language as `CreateWorktreeSheet` / `UpdatePromptView`. Parent owns
/// the actual close + `git worktree remove` via the `confirm` closure;
/// this view stays a pure form.
struct ConfirmRemoveWorktreeSheet: View {
    enum Outcome: Equatable {
        case success
        case failure(String)
    }

    let workspace: Workspace
    /// Closes the workspace and `git worktree remove`s the directory. The
    /// "keep dir" option is intentionally not exposed: sidebar = disk is
    /// the invariant the rest of the worktree code relies on (no orphan
    /// row, no dead-end). Caller still owns the close + pending-request
    /// cleanup before resolving.
    let confirm: @MainActor () async -> Outcome
    let dismiss: () -> Void

    @State private var isWorking: Bool = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusLabel
                .padding(.bottom, 18)

            headline
            subtitle
                .padding(.top, 6)

            Rectangle()
                .fill(Theme.chromeHairline)
                .frame(width: 32, height: 1)
                .padding(.vertical, 22)

            description

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
                BracketButton(isWorking ? "removing…" : "remove") { submit() }
                    .disabled(isWorking)
                    .opacity(isWorking ? 0.4 : 1)
            }
            .padding(.top, 22)
        }
        .padding(.vertical, 22)
        .padding(.horizontal, 28)
        .frame(width: 460, alignment: .topLeading)
        .background(Theme.chromeBackground)
        .preferredColorScheme(Theme.chromeColorScheme)
    }

    private var statusLabel: some View {
        Text("CLOSE-WORKTREE")
            .font(Theme.mono(10, weight: .medium))
            .tracking(1.6)
            .foregroundStyle(Theme.chromeMuted.opacity(0.85))
    }

    private var headline: some View {
        Text(workspace.title)
            .font(Theme.display(20, weight: .medium))
            .foregroundStyle(Theme.chromeForeground)
    }

    private var subtitle: some View {
        Text((workspace.workingDirectory.path as NSString).abbreviatingWithTildeInPath)
            .font(Theme.mono(11.5))
            .foregroundStyle(Theme.chromeMuted)
    }

    private var description: some View {
        Text("The worktree directory will be deleted. Uncommitted changes will be lost.")
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
            case .failure(let msg):
                isWorking = false
                errorMessage = msg
            }
        }
    }
}
