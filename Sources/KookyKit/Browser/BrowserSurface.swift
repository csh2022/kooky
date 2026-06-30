import Foundation

@MainActor
@Observable
final class BrowserSurface {
    let engine: any BrowserEngine
    var addressText: String
    private(set) var snapshot: BrowserEngineSnapshot

    init(engine: any BrowserEngine) {
        self.engine = engine
        self.snapshot = engine.snapshot
        self.addressText = engine.snapshot.urlString
        self.engine.onSnapshotChange = { [weak self] snapshot in
            self?.apply(snapshot)
        }
    }

    var title: String {
        if !snapshot.title.isEmpty { return snapshot.title }
        return "Browser"
    }

    func loadAddressText() {
        guard let request = BrowserLoadRequest(addressText) else { return }
        addressText = request.displayString
        engine.load(request)
    }

    func reloadOrStop() {
        if snapshot.isLoading {
            engine.stopLoading()
        } else {
            engine.reload()
        }
    }

    private func apply(_ next: BrowserEngineSnapshot) {
        snapshot = next
        if !next.urlString.isEmpty {
            addressText = next.urlString
        }
    }
}

