import SwiftUI

struct BrowserPaneView: View {
    @Bindable var browser: BrowserPane
    let onClose: () -> Void

    private let credentialVault: BrowserCredentialVault = KeychainBrowserCredentialVault.shared

    @State private var credentialForm: BrowserCredentialForm?
    @State private var savedAccounts: [String] = []
    @State private var credentialStatus: String?

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
        .task(id: browser.surface.snapshot.urlString) {
            await refreshCredentialState()
        }
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
            credentialControls
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

    @ViewBuilder
    private var credentialControls: some View {
        if !savedAccounts.isEmpty {
            Menu {
                ForEach(savedAccounts, id: \.self) { account in
                    Button(account) {
                        fillCredential(account: account)
                    }
                }
            } label: {
                Image(systemName: "key.fill")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .help("Fill Saved Password")
        }
        if credentialForm?.canSave == true {
            HoverableIconButton(systemName: "tray.and.arrow.down", fontSize: 12, size: 28, help: "Save Password") {
                saveCredential()
            }
        }
        if let credentialStatus {
            Text(credentialStatus)
                .font(Theme.mono(10))
                .foregroundStyle(Theme.chromeMuted)
                .lineLimit(1)
                .frame(maxWidth: 120, alignment: .trailing)
        }
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

    private func refreshCredentialState() async {
        let form = await browser.surface.engine.credentialForm()
        credentialForm = form
        if let site = form?.site, !site.isEmpty {
            savedAccounts = credentialVault.accounts(for: site)
        } else if let site = browser.surface.snapshot.siteOrigin {
            savedAccounts = credentialVault.accounts(for: site)
        } else {
            savedAccounts = []
        }
    }

    private func saveCredential() {
        Task { @MainActor in
            let form = await browser.surface.engine.credentialForm()
            guard let form, form.canSave else {
                credentialStatus = "No password"
                return
            }
            do {
                try credentialVault.save(BrowserCredential(
                    site: form.site,
                    account: form.account,
                    password: form.password
                ))
                credentialStatus = "Saved"
                await refreshCredentialState()
            } catch {
                credentialStatus = "Save failed"
            }
        }
    }

    private func fillCredential(account: String) {
        Task { @MainActor in
            let site = credentialForm?.site ?? browser.surface.snapshot.siteOrigin ?? ""
            guard let credential = credentialVault.credential(site: site, account: account) else {
                credentialStatus = "Not found"
                return
            }
            _ = await browser.surface.engine.fillCredential(credential)
            credentialStatus = "Filled"
            await refreshCredentialState()
        }
    }
}

private extension BrowserEngineSnapshot {
    var siteOrigin: String? {
        guard let url = URL(string: urlString),
              let scheme = url.scheme,
              let host = url.host
        else { return nil }
        var origin = "\(scheme)://\(host)"
        if let port = url.port {
            origin += ":\(port)"
        }
        return origin
    }
}
