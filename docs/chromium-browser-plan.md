# Chromium-backed Built-in Browser Plan

## Decision

Kooky should add a Chromium-backed browser engine through CEF while keeping
`WKWebView` as the default engine until Chromium is bundled, launched, and
validated in the app bundle.

The goal is not to become Google Chrome. The goal is a first-class embedded
browser for agents whose rendering, automation, and diagnostics are close enough
to desktop Chrome for common web work, with explicit fallback to the user's real
Chrome session for Google OAuth, Chrome account sync, extension-dependent flows,
and other sites that treat embedded browsers differently.

## Why CEF

- CEF is built for embedding Chromium in native applications.
- It fits Kooky's existing `BrowserEngine` abstraction: a Chromium engine can
  expose an `NSView` and implement the same navigation, inspection, screenshot,
  and interaction methods as `WebKitBrowserEngine`.
- It can enable Chrome DevTools Protocol style diagnostics through CEF remote
  debugging, which is a better fit for agent workflows than WebKit-only script
  evaluation.

Electron is not the preferred path because it would introduce a second app
runtime around the SwiftUI application instead of providing a native engine
inside the existing pane model.

## Non-goals

- Do not promise Chrome account sign-in, Chrome Sync, Google Password Manager,
  or full extension compatibility.
- Do not reuse the user's normal Chrome profile directly.
- Do not remove the WebKit engine until the Chromium engine has equivalent
  baseline coverage and a fallback story.
- Do not silently pretend Chromium is active when the CEF framework is missing.

## Product Behavior

- Default engine remains WebKit.
- `KOOKY_BROWSER_ENGINE=chromium` selects the Chromium path.
- Until CEF is bundled, selecting Chromium shows an explicit unavailable engine
  instead of falling back silently.
- When CEF is ready, Chromium uses a Kooky-owned persistent profile directory.
- Real Chrome fallback remains available for flows where parity depends on the
  user's Chrome identity, cookies, experiments, extensions, or OAuth policy.

## Implementation Stages

### Stage 1: Engine Selection Scaffold

- Add `BrowserEngineProvider`.
- Keep WebKit as the default.
- Add an explicit unavailable Chromium engine for builds without CEF.
- Add unit tests for engine selection.

### Stage 2: CEF Bundle and Helper Layout

- Add `scripts/setup-cef.sh` to download or locate a pinned CEF standard
  distribution for the host architecture. The initial pin is CEF
  `144.0.29+g0b1a012+chromium-144.0.7559.256` for macOS arm64, with sha1
  verification and environment overrides for version, platform, checksum, and
  URL.
- Teach `scripts/build-app.sh` to place
  `Chromium Embedded Framework.framework` and required helper apps under
  `Kooky.app/Contents/Frameworks/` when `Vendor/CEF/current` exists. Helper
  apps must be Kooky-built bundles; the setup script must not rename CEF sample
  helpers because their internal executable names and bundle metadata would not
  match Kooky's expected helper paths.
- Keep the binary payload out of git.
- Add packaging validation that fails when Chromium is selected but bundle
  assets are missing.

### Stage 3: Native Bridge

- Build `KookyCEFBridge.framework` outside the default SwiftPM target graph so
  developers without `Vendor/CEF` can still build Kooky normally.
- Bundle that bridge from `Vendor/CEFBridge/current` when it exists.
- Add an Objective-C++ CEF bridge target that owns CEF initialization, shutdown,
  browser creation, and the native browser `NSView`.
- Implement `ChromiumBrowserEngine` in Swift as a thin adapter over the bridge.
- Use a Kooky-specific profile/cache directory.
- Publish title, URL, loading state, and navigation availability through
  `BrowserEngineSnapshot`.

### Stage 4: Agent Automation Parity

- Implement the current `BrowserEngine` page interaction surface through CEF.
- Add CDP/remote-debugging backed console, network, file upload, dialog, and
  performance capture methods behind new protocol APIs instead of command stubs.
- Add SERP parity checks for Google `intitle:` searches against the user's real
  Chrome fallback path.

### Stage 5: Shipping Gate

- Run unit tests.
- Build the app bundle.
- Launch Kooky with WebKit default and Chromium selected.
- Verify a real page renders, snapshot/text/elements/screenshot work, and the
  app exits cleanly.
- Verify Google Search behavior, including whether result count appears for an
  `intitle:` query under both Kooky Chromium and real Chrome fallback.

## Risks

- macOS CEF packaging requires helper app bundles and notarization-friendly
  entitlements.
- CEF increases app size and creates an ongoing security update obligation.
- Google and other identity providers may still classify the embedded browser
  differently from installed Chrome.
- Remote debugging must be treated as a local-only development/agent surface and
  not exposed unintentionally.
