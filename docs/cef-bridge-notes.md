# CEF Bridge Notes

## Runtime Shape

Kooky should not link CEF directly into `KookyKit` while Chromium is optional.
The default SwiftPM build must continue to work without `Vendor/CEF`.

Use this shape:

- `Vendor/CEF/current`: ignored CEF download prepared by `scripts/setup-cef.sh`.
- `Vendor/CEFBridge/current/KookyCEFBridge.framework`: ignored native bridge
  product produced by a later bridge build script.
- `Kooky.app/Contents/Frameworks/Chromium Embedded Framework.framework`:
  copied by `scripts/build-app.sh` when CEF is present.
- `Kooky.app/Contents/Frameworks/Kooky Helper*.app`: copied by
  `scripts/build-app.sh` when helper apps are present.
- `Kooky.app/Contents/Frameworks/KookyCEFBridge.framework`: copied by
  `scripts/build-app.sh` when the native bridge is present.

`ChromiumBrowserRuntime` keeps the activation gate strict: the Chromium path is
unavailable until the CEF framework, helper apps, and bridge framework are all
inside the app bundle.

## Bridge API Direction

The bridge should expose a small Objective-C API that Swift can load at runtime,
instead of importing CEF headers from Swift:

- initialize CEF once for the process
- create one browser view for a URL/profile directory
- expose the native `NSView`
- load URLs, navigate, reload, stop
- publish title, URL, loading state, and history availability callbacks
- evaluate JavaScript and return strings for the existing agent commands
- shut down browser instances without shutting down global CEF prematurely

The first bridge milestone should render a page and publish snapshots. Agent
automation parity comes after that; do not block rendering on full CDP parity.
