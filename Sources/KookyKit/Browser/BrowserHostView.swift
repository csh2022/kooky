import AppKit
import SwiftUI

struct BrowserHostView: NSViewRepresentable {
    let engine: any BrowserEngine

    func makeNSView(context: Context) -> BrowserHostNSView {
        let host = BrowserHostNSView()
        host.attach(engine: engine)
        return host
    }

    func updateNSView(_ nsView: BrowserHostNSView, context: Context) {
        nsView.attach(engine: engine)
    }
}

final class BrowserHostNSView: NSView {
    private weak var currentEngineView: NSView?
    private var installedViews: [ObjectIdentifier: NSView] = [:]
    private var constraintsByView: [ObjectIdentifier: [NSLayoutConstraint]] = [:]

    func attach(engine: any BrowserEngine) {
        let nextView = engine.view
        let nextId = ObjectIdentifier(nextView)

        if installedViews[nextId] == nil || nextView.superview !== self {
            if let oldHost = nextView.superview as? BrowserHostNSView, oldHost !== self {
                oldHost.detachMovedView(nextView)
            }
            if let constraints = constraintsByView[nextId] {
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
            installedViews[nextId] = nextView
            constraintsByView[nextId] = constraints
        }

        guard currentEngineView !== nextView else {
            nextView.isHidden = false
            return
        }

        if let oldView = currentEngineView {
            let oldId = ObjectIdentifier(oldView)
            if oldView.superview === self {
                oldView.isHidden = true
            } else {
                installedViews.removeValue(forKey: oldId)
                constraintsByView.removeValue(forKey: oldId)
            }
        }

        currentEngineView = nextView
        nextView.isHidden = false
        needsLayout = true
    }

    private func detachMovedView(_ view: NSView) {
        let id = ObjectIdentifier(view)
        if let constraints = constraintsByView[id] {
            NSLayoutConstraint.deactivate(constraints)
        }
        installedViews.removeValue(forKey: id)
        constraintsByView.removeValue(forKey: id)
        if currentEngineView === view {
            currentEngineView = nil
        }
        view.removeFromSuperview()
    }
}
