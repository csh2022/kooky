import AppKit
import SwiftUI

struct TerminalView: NSViewRepresentable {
    let engine: any TerminalEngine
    /// Whether this pane is the workspace's active one. Set on the engine
    /// before the view mounts (`makeNSView` runs before `viewDidMoveToWindow`)
    /// so a workspace switch only re-focuses the active pane (issue #24).
    var grabsFocusOnMount = true

    func makeNSView(context: Context) -> TerminalHostView {
        let host = TerminalHostView()
        host.attach(engine: engine, grabsFocusOnMount: grabsFocusOnMount)
        return host
    }

    // Also on update, not just mount: clicking a sibling pane flips `isFocused`
    // in place (no re-mount → no `makeNSView`), so this keeps the engine flag in
    // sync with the pane's active state for the next re-mount.
    func updateNSView(_ nsView: TerminalHostView, context: Context) {
        nsView.attach(engine: engine, grabsFocusOnMount: grabsFocusOnMount)
    }
}

final class TerminalHostView: NSView {
    private var currentEngine: (any TerminalEngine)?
    private weak var currentEngineView: NSView?
    private var installedEngineViews: [ObjectIdentifier: NSView] = [:]
    private var constraintsByEngineView: [ObjectIdentifier: [NSLayoutConstraint]] = [:]

    func attach(engine: any TerminalEngine, grabsFocusOnMount: Bool) {
        engine.grabsFocusOnMount = grabsFocusOnMount
        let nextView = engine.view
        let nextId = ObjectIdentifier(nextView)

        if installedEngineViews[nextId] == nil || nextView.superview !== self {
            if let oldHost = nextView.superview as? TerminalHostView, oldHost !== self {
                oldHost.detachMovedEngineView(nextView)
            }
            if let constraints = constraintsByEngineView[nextId] {
                NSLayoutConstraint.deactivate(constraints)
            }
            nextView.translatesAutoresizingMaskIntoConstraints = false
            nextView.isHidden = true
            addSubview(nextView)
            let constraints = [
                nextView.leadingAnchor.constraint(equalTo: leadingAnchor),
                nextView.trailingAnchor.constraint(equalTo: trailingAnchor),
                nextView.topAnchor.constraint(equalTo: topAnchor),
                nextView.bottomAnchor.constraint(equalTo: bottomAnchor),
            ]
            NSLayoutConstraint.activate(constraints)
            installedEngineViews[nextId] = nextView
            constraintsByEngineView[nextId] = constraints
        }

        guard currentEngineView !== nextView else {
            engine.isRenderingActive = true
            nextView.isHidden = false
            return
        }

        if let oldView = currentEngineView {
            let oldId = ObjectIdentifier(oldView)
            if oldView.superview === self {
                currentEngine?.isRenderingActive = false
                oldView.isHidden = true
            } else {
                installedEngineViews.removeValue(forKey: oldId)
                constraintsByEngineView.removeValue(forKey: oldId)
            }
        }

        currentEngine = engine
        currentEngineView = nextView
        nextView.isHidden = false
        engine.isRenderingActive = true
        engine.flushSize()
    }

    private func detachMovedEngineView(_ view: NSView) {
        let id = ObjectIdentifier(view)
        if let constraints = constraintsByEngineView.removeValue(forKey: id) {
            NSLayoutConstraint.deactivate(constraints)
        }
        installedEngineViews.removeValue(forKey: id)
        if currentEngineView === view {
            currentEngine = nil
            currentEngineView = nil
        }
    }
}
