import SwiftUI

struct BrowserPaneView: View {
    @Bindable var browser: BrowserPane
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.chromeHairline).frame(height: 1)
            BrowserHostView(engine: browser.surface.engine)
                .overlay(alignment: .top) {
                    if let message = browser.surface.snapshot.errorMessage {
                        errorBanner(message)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.chromeBackground)
    }

    private var header: some View {
        HStack(spacing: 6) {
            HoverableIconButton(systemName: "chevron.left", fontSize: 12, size: 28, help: "Back") {
                browser.surface.engine.goBack()
            }
            .disabled(!browser.surface.snapshot.canGoBack)
            HoverableIconButton(systemName: "chevron.right", fontSize: 12, size: 28, help: "Forward") {
                browser.surface.engine.goForward()
            }
            .disabled(!browser.surface.snapshot.canGoForward)
            HoverableIconButton(
                systemName: browser.surface.snapshot.isLoading ? "xmark" : "arrow.clockwise",
                fontSize: 12,
                size: 28,
                help: browser.surface.snapshot.isLoading ? "Stop" : "Reload"
            ) {
                browser.surface.reloadOrStop()
            }
            TextField("Search or enter URL", text: addressBinding)
                .textFieldStyle(.plain)
                .font(Theme.mono(12))
                .foregroundStyle(Theme.chromeForeground)
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Theme.chromeActive)
                )
                .onSubmit {
                    browser.isUserTouched = true
                    browser.surface.loadAddressText()
                }
            HoverableIconButton(
                systemName: browser.isPinned ? "pin.fill" : "pin",
                fontSize: 12,
                size: 28,
                help: browser.isPinned ? "Unpin Browser" : "Pin Browser"
            ) {
                browser.isPinned.toggle()
                browser.isUserTouched = true
            }
            HoverableIconButton(systemName: "xmark", fontSize: 10, size: 28, help: "Close Browser") {
                onClose()
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
    }

    private var addressBinding: Binding<String> {
        Binding(
            get: { browser.surface.addressText },
            set: { browser.surface.addressText = $0 }
        )
    }

    private func errorBanner(_ message: String) -> some View {
        Text(message)
            .font(Theme.mono(11))
            .foregroundStyle(Theme.activityFailure)
            .lineLimit(2)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.chromeBackground.opacity(0.94))
    }
}
