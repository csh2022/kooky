# Repository Instructions

- This repository is maintained on the `dev` branch. Do not merge, commit, or
  push feature/fix work to `main` unless the user explicitly asks for `main`.
  For normal delivery, merge the agent worktree branch back into `dev`, run the
  relevant validation on `dev`, and push `origin dev`.
- After completing and validating code changes, temporarily launch the app or relevant local service for a smoke check. Report the launch command, outcome, and any local URL or app status in the final response.
- When merging branches, preserve the original commits. Do not squash, rebase, amend, or otherwise rewrite commit history unless explicitly requested.
