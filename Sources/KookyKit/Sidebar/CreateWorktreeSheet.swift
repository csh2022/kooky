import AppKit
import SwiftUI

/// Brutalist sheet for creating a git worktree from a source workspace.
/// Same visual language as `UpdatePromptView` / Settings — `Theme.chrome*`
/// tokens, mono kebab-case labels, sharp corners, 1pt hairlines, bracket
/// buttons. Form-only: the parent owns the actual git + workspace
/// materialization via the `create` closure and dismisses on success.
struct CreateWorktreeSheet: View {
    /// Parent passes this back from `create` so the sheet can surface
    /// failure inline (user fixes the branch name / path and retries)
    /// instead of dismissing.
    enum CreateOutcome: Equatable {
        case success
        case failure(String)
    }

    /// Bundle of form output handed to `create`.
    struct Request {
        let mode: WorktreeManager.BranchMode
        let path: URL
        /// Either the existing branch name or the new branch name — the
        /// value sidebar shows under `Workspace.worktreeBranch`.
        let branchForDisplay: String
        let template: AgentTemplate
    }

    let source: Workspace
    let launchTemplates: [AgentTemplate]
    let defaultLaunchTemplate: AgentTemplate
    let create: @MainActor (Request) async -> CreateOutcome
    let dismiss: () -> Void

    private enum BranchModeUI: Hashable { case newBranch, existing }

    @State private var branchMode: BranchModeUI = .newBranch
    @State private var newBranchName: String = ""
    @State private var newBranchBase: String = ""
    @State private var existingBranch: String = ""
    /// Loaded off-thread via `.task` on first sheet appear so the main
    /// thread doesn't block on `git for-each-ref` while the user is
    /// typing. Empty until the subprocess returns.
    @State private var availableBranches: [String] = []
    @State private var branchesLoaded: Bool = false
    /// Stable git root for the source workspace. `Workspace.workingDirectory`
    /// follows the active shell cwd, so it may be a nested folder by the time
    /// the user opens this sheet.
    @State private var sourceRoot: URL?
    /// User override for the auto-computed `<repo>-<branch>` sibling path.
    /// Empty = use the computed default at submit time. Lives only in
    /// the advanced section.
    @State private var worktreePathOverride: String = ""
    @State private var selectedTemplate: AgentTemplate?
    @State private var isAdvancedExpanded: Bool = false
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

            form

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
                BracketButton(isWorking ? "creating…" : "create") {
                    submit()
                }
                .disabled(isWorking || !canSubmit)
                .opacity(canSubmit && !isWorking ? 1 : 0.4)
            }
            .padding(.top, 22)
        }
        .padding(.vertical, 22)
        .padding(.horizontal, 28)
        .frame(width: 480, alignment: .topLeading)
        .background(Theme.chromeBackground)
        .preferredColorScheme(Theme.chromeColorScheme)
        .onAppear(perform: prefill)
        .task {
            // First render: kick off branch enumeration off the main
            // thread. The picker stays empty until this returns; the
            // sheet starts on `.newBranch` mode so most users never
            // wait on this.
            guard !branchesLoaded else { return }
            let cwd = source.workingDirectory
            let loaded = await Task.detached(priority: .userInitiated) {
                (
                    root: WorktreeManager.repoRoot(near: cwd),
                    branches: GitBranchInventory.localBranches(cwd: cwd)
                )
            }.value
            sourceRoot = loaded.root
            let branches = loaded.branches
            availableBranches = branches
            if existingBranch.isEmpty { existingBranch = branches.first ?? "" }
            branchesLoaded = true
        }
    }

    // MARK: Sections

    private var statusLabel: some View {
        Text("CREATE-WORKTREE")
            .font(Theme.mono(10, weight: .medium))
            .tracking(1.6)
            .foregroundStyle(Theme.chromeMuted.opacity(0.85))
    }

    private var headline: some View {
        Text(source.title)
            .font(Theme.display(20, weight: .medium))
            .foregroundStyle(Theme.chromeForeground)
    }

    private var subtitle: some View {
        Text((sourcePathForDisplay.path as NSString).abbreviatingWithTildeInPath)
            .font(Theme.mono(11.5))
            .foregroundStyle(Theme.chromeMuted)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Main field — Conductor-style single input. 90% of "new
            // worktree" flows are "branch off HEAD, launch default agent";
            // anything else is one disclosure away.
            VStack(alignment: .leading, spacing: 6) {
                fieldLabel(branchMode == .newBranch ? "branch-name" : "branch")
                switch branchMode {
                case .newBranch:
                    TextField("feat-x", text: $newBranchName)
                        .textFieldStyle(.plain)
                        .font(Theme.mono(12))
                        .foregroundStyle(Theme.chromeForeground)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .bracketBorder()
                case .existing:
                    if !branchesLoaded {
                        Text("loading branches…")
                            .font(Theme.mono(11.5))
                            .foregroundStyle(Theme.chromeMuted)
                    } else if availableBranches.isEmpty {
                        Text("no local branches found")
                            .font(Theme.mono(11.5))
                            .foregroundStyle(Theme.chromeMuted)
                    } else {
                        Picker("", selection: $existingBranch) {
                            ForEach(availableBranches, id: \.self) { b in
                                Text(b).tag(b)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }
                }
            }

            advancedToggle

            if isAdvancedExpanded {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        fieldLabel("mode")
                        Picker("", selection: $branchMode) {
                            Text("new").tag(BranchModeUI.newBranch)
                            Text("existing").tag(BranchModeUI.existing)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    editRow(label: "worktree-path", text: $worktreePathOverride, placeholder: defaultPath)
                    if branchMode == .newBranch {
                        editRow(label: "base (defaults to HEAD)", text: $newBranchBase, placeholder: "main")
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        fieldLabel("launch")
                        Picker("", selection: Binding(
                            get: { selectedTemplate ?? defaultLaunchTemplate },
                            set: { selectedTemplate = $0 }
                        )) {
                            ForEach(launchTemplates) { t in
                                Text(t.title).tag(t)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }
                }
            }
        }
    }

    private var advancedToggle: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) {
                isAdvancedExpanded.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(isAdvancedExpanded ? 90 : 0))
                Text("advanced")
                    .font(Theme.mono(10, weight: .medium))
                    .tracking(1.2)
            }
            .foregroundStyle(Theme.chromeMuted.opacity(0.85))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(Theme.mono(10, weight: .medium))
            .tracking(1.2)
            .foregroundStyle(Theme.chromeMuted.opacity(0.85))
    }

    @ViewBuilder
    private func editRow(label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldLabel(label)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(Theme.mono(12))
                .foregroundStyle(Theme.chromeForeground)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .bracketBorder()
        }
    }

    // MARK: Logic

    private var canSubmit: Bool {
        switch branchMode {
        case .newBranch:
            return !newBranchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .existing:
            // Block submit until branches finish loading so a quick toggle
            // doesn't fire `create` with `existingBranch = ""`.
            return branchesLoaded && !availableBranches.isEmpty && !existingBranch.isEmpty
        }
    }

    private func prefill() {
        if selectedTemplate == nil {
            selectedTemplate = defaultLaunchTemplate
        }
    }

    /// Branch the user is about to act on (new or existing). Drives the
    /// auto-computed `worktree-path` placeholder so it always reads as a
    /// finished proposal, not a half-filled `<repo>-` stub.
    private var currentBranchName: String {
        switch branchMode {
        case .newBranch:
            return newBranchName.trimmingCharacters(in: .whitespacesAndNewlines)
        case .existing:
            return existingBranch
        }
    }

    /// Sibling of the source repo: `<parent>/<repo-name>-<branch>`.
    /// Falls back to `<repo-name>-` when no branch has been typed yet so
    /// the placeholder still hints at the path's shape.
    private var defaultPath: String {
        let root = sourceRoot ?? source.workingDirectory
        let parentDir = root.deletingLastPathComponent()
        let base = root.lastPathComponent
        let suffix = currentBranchName.isEmpty ? "" : currentBranchName
        let candidate = parentDir.appendingPathComponent("\(base)-\(suffix)").path
        return (candidate as NSString).abbreviatingWithTildeInPath
    }

    private var sourcePathForDisplay: URL {
        sourceRoot ?? source.workingDirectory
    }

    private func submit() {
        // worktree-path falls back to the auto-computed default when the
        // user didn't expand advanced (or left it blank). The override
        // wins only when non-empty.
        let override = worktreePathOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectivePath = override.isEmpty ? defaultPath : override
        let expanded = (effectivePath as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)

        let mode: WorktreeManager.BranchMode
        let branchForDisplay: String
        switch branchMode {
        case .newBranch:
            let name = newBranchName.trimmingCharacters(in: .whitespacesAndNewlines)
            let base = newBranchBase.trimmingCharacters(in: .whitespacesAndNewlines)
            mode = .newBranch(name: name, base: base.isEmpty ? nil : base)
            branchForDisplay = name
        case .existing:
            mode = .existing(branch: existingBranch)
            branchForDisplay = existingBranch
        }

        let request = Request(
            mode: mode,
            path: url,
            branchForDisplay: branchForDisplay,
            template: selectedTemplate ?? defaultLaunchTemplate
        )

        isWorking = true
        errorMessage = nil
        Task {
            let outcome = await create(request)
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
