# Repository Instructions

- This repository is maintained on the `dev` branch. Do not merge, commit, or
  push feature/fix work to `main` unless the user explicitly asks for `main`.
  For normal delivery, merge the agent worktree branch back into `dev`, run the
  relevant validation on `dev`, and push `origin dev`.
- After completing and validating code changes, temporarily launch the app or relevant local service for a smoke check. Report the launch command, outcome, and any local URL or app status in the final response.
- When merging branches, preserve the original commits. Do not squash, rebase, amend, or otherwise rewrite commit history unless explicitly requested.
- A packaged or installed Kooky app is valid only when it contains the complete
  Chromium runtime: `Chromium Embedded Framework.framework`,
  `KookyCEFBridge.framework`, and all four `Kooky Helper*.app` bundles. Never
  skip these components because they are large, slow to download, or because
  WebKit can launch. Use `scripts/build-app.sh` for app bundles and run
  `scripts/verify-cef-app.sh` before installing, replacing, packaging a DMG, or
  reporting success. Missing components are a hard failure, not a supported
  degraded mode. Reuse the checksum-verified archives under
  `~/Library/Caches/Kooky/` across worktrees; do not bypass checksum validation
  or solve download cost by omitting runtime dependencies.
