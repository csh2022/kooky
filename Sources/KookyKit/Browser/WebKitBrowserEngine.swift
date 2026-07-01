import AppKit
import WebKit

@MainActor
final class WebKitBrowserEngine: NSObject, BrowserEngine, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    var onSnapshotChange: ((BrowserEngineSnapshot) -> Void)?

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        publishSnapshot()
    }

    var view: NSView { webView }

    var snapshot: BrowserEngineSnapshot {
        BrowserEngineSnapshot(
            title: webView.title ?? "Browser",
            urlString: webView.url?.absoluteString ?? "",
            canGoBack: webView.canGoBack,
            canGoForward: webView.canGoForward,
            isLoading: webView.isLoading,
            errorMessage: nil
        )
    }

    func load(_ request: BrowserLoadRequest) {
        webView.load(URLRequest(url: request.url))
        publishSnapshot()
    }

    func reload() {
        webView.reload()
        publishSnapshot()
    }

    func stopLoading() {
        webView.stopLoading()
        publishSnapshot()
    }

    func goBack() {
        guard webView.canGoBack else { return }
        webView.goBack()
        publishSnapshot()
    }

    func goForward() {
        guard webView.canGoForward else { return }
        webView.goForward()
        publishSnapshot()
    }

    func click(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        evaluate(Self.clickJavaScript(text: trimmed))
    }

    func clickElement(id: String, double: Bool) async -> String {
        let result = await evaluateString(Self.clickElementJavaScript(id: id, double: double))
        return result == "true" ? "ok clicked id: \(id)\n" : "element not found: \(id)\n"
    }

    func clickAt(x: Double, y: Double) async -> String {
        let result = await evaluateString(Self.clickAtJavaScript(x: x, y: y))
        return result == "true" ? "ok clicked at: \(x),\(y)\n" : "click target not found at: \(x),\(y)\n"
    }

    func fill(field: String, text: String) async -> String {
        let trimmed = field.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "field not found\n" }
        let result = await evaluateString(Self.fillJavaScript(field: trimmed, text: text))
        return result == "true" ? "ok filled field: \(trimmed)\n" : "field not found: \(trimmed)\n"
    }

    func fillElement(id: String, text: String) async -> String {
        let result = await evaluateString(Self.fillElementJavaScript(id: id, text: text))
        return result == "true" ? "ok filled id: \(id)\n" : "element not found or not fillable: \(id)\n"
    }

    func clear(field: String?) async -> String {
        let result = await evaluateString(Self.clearJavaScript(field: field ?? ""))
        return result == "true" ? "ok cleared\n" : "field not found\n"
    }

    func type(text: String) {
        guard !text.isEmpty else { return }
        evaluate(Self.typeJavaScript(text: text))
    }

    func paste(text: String) {
        guard !text.isEmpty else { return }
        evaluate(Self.typeJavaScript(text: text))
    }

    func press(key: String) async -> String {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "key press failed\n" }
        let result = await evaluateString(Self.pressJavaScript(key: trimmed))
        switch result {
        case "submitted":
            return "ok pressed key: \(trimmed)\nsubmitted: true\n"
        case "clicked-submit":
            return "ok pressed key: \(trimmed)\nclickedSubmit: true\n"
        case "pressed":
            return "ok pressed key: \(trimmed)\n"
        default:
            return "key press failed: \(trimmed)\n"
        }
    }

    func hotkey(_ combo: String) {
        let trimmed = combo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        evaluate(Self.hotkeyJavaScript(combo: trimmed))
    }

    func scroll(direction: String, amount: Double?) async -> String {
        let result = await evaluateString(Self.scrollJavaScript(direction: direction, amount: amount))
        return result.isEmpty ? "scroll failed\n" : result.ensuringTrailingNewline()
    }

    func hover(id: String) async -> String {
        let result = await evaluateString(Self.hoverJavaScript(id: id))
        return result == "true" ? "ok hovered id: \(id)\n" : "element not found: \(id)\n"
    }

    func waitForText(_ text: String, timeoutMilliseconds: Int) async -> String {
        await waitForCondition(
            label: "text",
            text: text,
            timeoutMilliseconds: timeoutMilliseconds
        ) { [weak self] in
            guard let self else { return "" }
            return await self.pageText()
        }
    }

    func waitForURL(_ text: String, timeoutMilliseconds: Int) async -> String {
        await waitForCondition(
            label: "url",
            text: text,
            timeoutMilliseconds: timeoutMilliseconds
        ) { [weak self] in
            self?.snapshot.urlString ?? ""
        }
    }

    func waitForTitle(_ text: String, timeoutMilliseconds: Int) async -> String {
        await waitForCondition(
            label: "title",
            text: text,
            timeoutMilliseconds: timeoutMilliseconds
        ) { [weak self] in
            self?.snapshot.title ?? ""
        }
    }

    func pageText() async -> String {
        await evaluateString(Self.pageTextJavaScript()).trimmedForCLI()
    }

    func pageHTML() async -> String {
        await evaluateString("document.documentElement ? document.documentElement.outerHTML : ''").trimmedForCLI()
    }

    func linksJSONLines() async -> String {
        await evaluateString(Self.linksJavaScript()).ensuringTrailingNewline()
    }

    func elementsJSONLines() async -> String {
        await evaluateString(Self.elementsJavaScript()).ensuringTrailingNewline()
    }

    func pageSnapshot() async -> String {
        let state = browserStateText(prefix: "Kooky browser snapshot")
        let elements = await elementsJSONLines()
        let text = await pageText()
        return """
        \(state)
        Elements:
        \(elements)
        Text:
        \(text)
        """.ensuringTrailingNewline()
    }

    func saveScreenshot(to path: String?) async -> String {
        let resolved = screenshotPath(path)
        let config = WKSnapshotConfiguration()
        if webView.bounds.width > 0, webView.bounds.height > 0 {
            config.rect = webView.bounds
        } else {
            config.rect = NSRect(x: 0, y: 0, width: 1280, height: 800)
        }
        guard let image = await takeSnapshot(configuration: config),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:])
        else {
            return "screenshot failed\n"
        }
        do {
            try FileManager.default.createDirectory(
                at: resolved.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: resolved, options: .atomic)
            return resolved.path + "\n"
        } catch {
            return "screenshot failed: \(error.localizedDescription)\n"
        }
    }

    func credentialForm() async -> BrowserCredentialForm? {
        let json = await evaluateString(Self.credentialFormJavaScript())
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let site = object["site"] as? String,
              let account = object["account"] as? String,
              let password = object["password"] as? String
        else { return nil }
        return BrowserCredentialForm(site: site, account: account, password: password)
    }

    func fillCredential(_ credential: BrowserCredential) async -> String {
        guard !credential.account.isEmpty, !credential.password.isEmpty else {
            return "credential is empty\n"
        }
        let result = await evaluateString(Self.fillCredentialJavaScript(
            account: credential.account,
            password: credential.password
        ))
        return result == "true" ? "ok filled credential: \(credential.account)\n" : "credential form not found\n"
    }

    private func waitForCondition(
        label: String,
        text: String,
        timeoutMilliseconds: Int,
        value: () async -> String
    ) async -> String {
        let deadline = Date().addingTimeInterval(TimeInterval(max(timeoutMilliseconds, 0)) / 1000.0)
        repeat {
            let current = await value()
            if current.localizedCaseInsensitiveContains(text) {
                return browserStateText(prefix: "ok found \(label): \(text)", condition: label)
            }
            if Date() >= deadline { break }
            try? await Task.sleep(nanoseconds: 200_000_000)
        } while true
        return browserStateText(prefix: "timed out waiting for \(label): \(text)", condition: label)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        publishSnapshot()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        publishSnapshot()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        publishSnapshot()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        publishSnapshot(errorMessage: error.localizedDescription)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        publishSnapshot(errorMessage: error.localizedDescription)
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }

    private func publishSnapshot(errorMessage: String? = nil) {
        onSnapshotChange?(BrowserEngineSnapshot(
            title: webView.title ?? "Browser",
            urlString: webView.url?.absoluteString ?? "",
            canGoBack: webView.canGoBack,
            canGoForward: webView.canGoForward,
            isLoading: webView.isLoading,
            errorMessage: errorMessage
        ))
    }

    private func evaluate(_ script: String) {
        webView.evaluateJavaScript(script) { [weak self] _, error in
            if let error {
                Task { @MainActor in self?.publishSnapshot(errorMessage: error.localizedDescription) }
            }
        }
    }

    private func evaluateString(_ script: String) async -> String {
        await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script) { [weak self] result, error in
                if let error {
                    Task { @MainActor in self?.publishSnapshot(errorMessage: error.localizedDescription) }
                    continuation.resume(returning: "")
                    return
                }
                if let string = result as? String {
                    continuation.resume(returning: string)
                } else if let bool = result as? Bool {
                    continuation.resume(returning: bool ? "true" : "false")
                } else if let number = result as? NSNumber {
                    continuation.resume(returning: number.stringValue)
                } else {
                    continuation.resume(returning: "")
                }
            }
        }
    }

    private func takeSnapshot(configuration: WKSnapshotConfiguration) async -> NSImage? {
        await withCheckedContinuation { continuation in
            webView.takeSnapshot(with: configuration) { image, error in
                if error != nil {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: image)
                }
            }
        }
    }

    private func browserStateText(prefix: String, condition: String? = nil) -> String {
        let snapshot = self.snapshot
        let conditionLine = condition.map { "condition: \($0)\n" } ?? ""
        return """
        \(prefix)
        \(conditionLine)title: \(snapshot.title)
        url: \(snapshot.urlString)
        loading: \(snapshot.isLoading)

        """
    }

    private func screenshotPath(_ path: String?) -> URL {
        if let path, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let expanded = (path as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded)
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kooky-browser", isDirectory: true)
        let stamp = Self.screenshotTimestamp.string(from: Date())
        return dir.appendingPathComponent("screenshot-\(stamp).png")
    }

    private static let screenshotTimestamp: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmmss-SSS"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = .current
        return fmt
    }()

    private static func clickJavaScript(text: String) -> String {
        let needle = javaScriptStringLiteral(text)
        return """
        (() => {
          const needle = \(needle).trim().toLowerCase();
          if (!needle) return false;
          const textFor = (el) => [
            el.innerText,
            el.textContent,
            el.getAttribute && el.getAttribute('aria-label'),
            el.getAttribute && el.getAttribute('title'),
            el.value,
            el.href
          ].filter(Boolean).join(' ').replace(/\\s+/g, ' ').trim().toLowerCase();
          const visible = (el) => {
            const style = window.getComputedStyle(el);
            if (style.visibility === 'hidden' || style.display === 'none' || Number(style.opacity) === 0) return false;
            const rect = el.getBoundingClientRect();
            return rect.width > 0 && rect.height > 0 && rect.bottom >= 0 && rect.right >= 0 &&
              rect.top <= (window.innerHeight || document.documentElement.clientHeight) &&
              rect.left <= (window.innerWidth || document.documentElement.clientWidth);
          };
          const selectors = [
            'a',
            'button',
            '[role="link"]',
            '[role="button"]',
            'input[type="button"]',
            'input[type="submit"]',
            'summary',
            '[onclick]'
          ];
          const candidates = Array.from(document.querySelectorAll(selectors.join(',')));
          const exact = candidates.find((el) => visible(el) && textFor(el) === needle);
          const partial = candidates.find((el) => visible(el) && textFor(el).includes(needle));
          const target = exact || partial;
          if (!target) return false;
          target.scrollIntoView({ block: 'center', inline: 'center' });
          target.click();
          return true;
        })();
        """
    }

    private static func clickElementJavaScript(id: String, double: Bool) -> String {
        let id = javaScriptStringLiteral(id)
        let event = double ? "dblclick" : "click"
        return """
        (() => {
          const target = window.__kookyElementById && window.__kookyElementById(\(id));
          if (!target) return false;
          target.scrollIntoView({ block: 'center', inline: 'center' });
          target.focus && target.focus();
          target.dispatchEvent(new MouseEvent('mouseover', { bubbles: true, cancelable: true, view: window }));
          target.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true, view: window }));
          target.dispatchEvent(new MouseEvent('mouseup', { bubbles: true, cancelable: true, view: window }));
          target.dispatchEvent(new MouseEvent('\(event)', { bubbles: true, cancelable: true, view: window }));
          if ('\(event)' === 'click') target.click && target.click();
          return true;
        })();
        """
    }

    private static func clickAtJavaScript(x: Double, y: Double) -> String {
        """
        (() => {
          const x = \(x);
          const y = \(y);
          const target = document.elementFromPoint(x, y);
          if (!target) return false;
          target.dispatchEvent(new MouseEvent('mouseover', { bubbles: true, cancelable: true, view: window, clientX: x, clientY: y }));
          target.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true, view: window, clientX: x, clientY: y }));
          target.dispatchEvent(new MouseEvent('mouseup', { bubbles: true, cancelable: true, view: window, clientX: x, clientY: y }));
          target.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, view: window, clientX: x, clientY: y }));
          target.click && target.click();
          return true;
        })();
        """
    }

    private static func fillJavaScript(field: String, text: String) -> String {
        let field = javaScriptStringLiteral(field)
        let value = javaScriptStringLiteral(text)
        return """
        (() => {
          const needle = \(field).trim().toLowerCase();
          const value = \(value);
          if (!needle) return false;
          const visible = (el) => {
            const style = window.getComputedStyle(el);
            if (style.visibility === 'hidden' || style.display === 'none' || Number(style.opacity) === 0) return false;
            const rect = el.getBoundingClientRect();
            return rect.width > 0 && rect.height > 0;
          };
          const labelText = (el) => {
            const id = el.id;
            const direct = id ? document.querySelector(`label[for="${CSS.escape(id)}"]`) : null;
            const wrapping = el.closest && el.closest('label');
            return [direct && direct.innerText, wrapping && wrapping.innerText].filter(Boolean).join(' ');
          };
          const textFor = (el) => [
            el.getAttribute && el.getAttribute('aria-label'),
            el.getAttribute && el.getAttribute('placeholder'),
            el.getAttribute && el.getAttribute('name'),
            el.getAttribute && el.getAttribute('title'),
            labelText(el),
            el.innerText,
            el.textContent
          ].filter(Boolean).join(' ').replace(/\\s+/g, ' ').trim().toLowerCase();
          const fields = Array.from(document.querySelectorAll('input:not([type="hidden"]), textarea, [contenteditable="true"], [role="textbox"]'))
            .filter(visible);
          const exact = fields.find((el) => textFor(el) === needle);
          const partial = fields.find((el) => textFor(el).includes(needle));
          const target = exact || partial;
          if (!target) return false;
          const dispatchInput = (el, inputType, data) => {
            try {
              el.dispatchEvent(new InputEvent('input', { bubbles: true, inputType, data }));
            } catch {
              el.dispatchEvent(new Event('input', { bubbles: true }));
            }
          };
          const setNativeValue = (el, next) => {
            if (el.isContentEditable) {
              el.textContent = next;
              return true;
            }
            if (!('value' in el)) return false;
            const proto = el instanceof HTMLTextAreaElement
              ? HTMLTextAreaElement.prototype
              : (el instanceof HTMLInputElement ? HTMLInputElement.prototype : null);
            const descriptor = proto ? Object.getOwnPropertyDescriptor(proto, 'value') : null;
            if (descriptor && descriptor.set) {
              descriptor.set.call(el, next);
            } else {
              el.value = next;
            }
            return true;
          };
          target.scrollIntoView({ block: 'center', inline: 'center' });
          target.focus();
          if (!setNativeValue(target, value)) return false;
          dispatchInput(target, 'insertText', value);
          target.dispatchEvent(new Event('change', { bubbles: true }));
          return true;
        })();
        """
    }

    private static func fillElementJavaScript(id: String, text: String) -> String {
        let id = javaScriptStringLiteral(id)
        let value = javaScriptStringLiteral(text)
        return """
        (() => {
          const target = window.__kookyElementById && window.__kookyElementById(\(id));
          const value = \(value);
          if (!target) return false;
          const dispatchInput = (el, inputType, data) => {
            try {
              el.dispatchEvent(new InputEvent('input', { bubbles: true, inputType, data }));
            } catch {
              el.dispatchEvent(new Event('input', { bubbles: true }));
            }
          };
          const setNativeValue = (el, next) => {
            if (el.isContentEditable) {
              el.textContent = next;
              return true;
            }
            if (!('value' in el)) return false;
            const proto = el instanceof HTMLTextAreaElement
              ? HTMLTextAreaElement.prototype
              : (el instanceof HTMLInputElement ? HTMLInputElement.prototype : null);
            const descriptor = proto ? Object.getOwnPropertyDescriptor(proto, 'value') : null;
            if (descriptor && descriptor.set) {
              descriptor.set.call(el, next);
            } else {
              el.value = next;
            }
            return true;
          };
          target.scrollIntoView({ block: 'center', inline: 'center' });
          target.focus && target.focus();
          if (!setNativeValue(target, value)) return false;
          dispatchInput(target, 'insertText', value);
          target.dispatchEvent(new Event('change', { bubbles: true }));
          return true;
        })();
        """
    }

    private static func credentialFormJavaScript() -> String {
        """
        (() => {
          const visible = (el) => {
            if (!el) return false;
            const style = window.getComputedStyle(el);
            if (style.visibility === 'hidden' || style.display === 'none' || Number(style.opacity) === 0) return false;
            const rect = el.getBoundingClientRect();
            return rect.width > 0 && rect.height > 0;
          };
          const inputs = Array.from(document.querySelectorAll('input')).filter(visible);
          const password = inputs.find((el) => (el.type || '').toLowerCase() === 'password');
          if (!password) return '';
          const usable = (el) => {
            const type = (el.type || 'text').toLowerCase();
            return ['text', 'email', 'tel', 'url', 'search', ''].includes(type);
          };
          const score = (el) => {
            const fields = [
              el.autocomplete,
              el.name,
              el.id,
              el.placeholder,
              el.getAttribute('aria-label')
            ].filter(Boolean).join(' ').toLowerCase();
            if (/user|login|email|account|mail|name|phone|identifier/.test(fields)) return 3;
            return 1;
          };
          const prior = inputs
            .filter((el) => usable(el))
            .filter((el) => {
              const a = el.compareDocumentPosition(password);
              return Boolean(a & Node.DOCUMENT_POSITION_FOLLOWING);
            })
            .sort((a, b) => score(b) - score(a));
          const account = prior[0] || inputs.find((el) => usable(el));
          if (!account) return '';
          return JSON.stringify({
            site: location.origin || '',
            account: account.value || '',
            password: password.value || ''
          });
        })();
        """
    }

    private static func fillCredentialJavaScript(account: String, password: String) -> String {
        let account = javaScriptStringLiteral(account)
        let password = javaScriptStringLiteral(password)
        return """
        (() => {
          const accountValue = \(account);
          const passwordValue = \(password);
          const visible = (el) => {
            if (!el) return false;
            const style = window.getComputedStyle(el);
            if (style.visibility === 'hidden' || style.display === 'none' || Number(style.opacity) === 0) return false;
            const rect = el.getBoundingClientRect();
            return rect.width > 0 && rect.height > 0;
          };
          const setNativeValue = (el, next) => {
            if (!('value' in el)) return false;
            const proto = el instanceof HTMLTextAreaElement
              ? HTMLTextAreaElement.prototype
              : (el instanceof HTMLInputElement ? HTMLInputElement.prototype : null);
            const descriptor = proto ? Object.getOwnPropertyDescriptor(proto, 'value') : null;
            if (descriptor && descriptor.set) {
              descriptor.set.call(el, next);
            } else {
              el.value = next;
            }
            try {
              el.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: next }));
            } catch {
              el.dispatchEvent(new Event('input', { bubbles: true }));
            }
            el.dispatchEvent(new Event('change', { bubbles: true }));
            return true;
          };
          const inputs = Array.from(document.querySelectorAll('input')).filter(visible);
          const passwordInput = inputs.find((el) => (el.type || '').toLowerCase() === 'password');
          if (!passwordInput) return false;
          const usable = (el) => {
            const type = (el.type || 'text').toLowerCase();
            return ['text', 'email', 'tel', 'url', 'search', ''].includes(type);
          };
          const score = (el) => {
            const fields = [
              el.autocomplete,
              el.name,
              el.id,
              el.placeholder,
              el.getAttribute('aria-label')
            ].filter(Boolean).join(' ').toLowerCase();
            if (/user|login|email|account|mail|name|phone|identifier/.test(fields)) return 3;
            return 1;
          };
          const prior = inputs
            .filter((el) => usable(el))
            .filter((el) => Boolean(el.compareDocumentPosition(passwordInput) & Node.DOCUMENT_POSITION_FOLLOWING))
            .sort((a, b) => score(b) - score(a));
          const accountInput = prior[0] || inputs.find((el) => usable(el));
          if (!accountInput) return false;
          accountInput.scrollIntoView({ block: 'center', inline: 'center' });
          setNativeValue(accountInput, accountValue);
          setNativeValue(passwordInput, passwordValue);
          passwordInput.focus();
          return true;
        })();
        """
    }

    private static func clearJavaScript(field: String) -> String {
        let field = javaScriptStringLiteral(field)
        return """
        (() => {
          const needle = \(field).trim().toLowerCase();
          let target = null;
          if (!needle) {
            target = document.activeElement;
          } else {
            const fields = Array.from(document.querySelectorAll('input:not([type="hidden"]), textarea, [contenteditable="true"], [role="textbox"]'));
            const textFor = (el) => [
              el.getAttribute && el.getAttribute('aria-label'),
              el.getAttribute && el.getAttribute('placeholder'),
              el.getAttribute && el.getAttribute('name'),
              el.getAttribute && el.getAttribute('title'),
              el.innerText,
              el.textContent
            ].filter(Boolean).join(' ').replace(/\\s+/g, ' ').trim().toLowerCase();
            target = fields.find((el) => textFor(el) === needle) || fields.find((el) => textFor(el).includes(needle));
          }
          if (!target || target === document.body || target === document.documentElement) return false;
          target.focus && target.focus();
          if (target.isContentEditable) {
            target.textContent = '';
          } else if ('value' in target) {
            target.value = '';
          } else {
            return false;
          }
          target.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'deleteContent' }));
          target.dispatchEvent(new Event('change', { bubbles: true }));
          return true;
        })();
        """
    }

    private static func typeJavaScript(text: String) -> String {
        let value = javaScriptStringLiteral(text)
        return """
        (() => {
          const value = \(value);
          const target = document.activeElement;
          if (!target || target === document.body || target === document.documentElement) return false;
          target.focus();
          if (target.isContentEditable) {
            document.execCommand('insertText', false, value);
          } else if ('value' in target) {
            const start = target.selectionStart ?? target.value.length;
            const end = target.selectionEnd ?? target.value.length;
            target.value = target.value.slice(0, start) + value + target.value.slice(end);
            const next = start + value.length;
            if (target.setSelectionRange) target.setSelectionRange(next, next);
          } else {
            return false;
          }
          target.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: value }));
          target.dispatchEvent(new Event('change', { bubbles: true }));
          return true;
        })();
        """
    }

    private static func pressJavaScript(key: String) -> String {
        let key = javaScriptStringLiteral(key)
        return """
        (() => {
          const key = \(key);
          const target = document.activeElement || document.body;
          if (!target) return 'failed';
          const eventInit = { key, code: key, bubbles: true, cancelable: true };
          const submitControlSelector = [
            'button[type="submit"]',
            'input[type="submit"]',
            'button:not([type])'
          ].join(',');
          const visible = (el) => {
            if (!el) return false;
            const style = window.getComputedStyle(el);
            if (style.visibility === 'hidden' || style.display === 'none' || Number(style.opacity) === 0) return false;
            const rect = el.getBoundingClientRect();
            return rect.width > 0 && rect.height > 0;
          };
          const dispatchKey = (type) => target.dispatchEvent(new KeyboardEvent(type, eventInit));
          dispatchKey('keydown');
          if (key.length === 1) dispatchKey('keypress');
          let result = 'pressed';
          if ('value' in target) {
            const value = target.value ?? '';
            const start = target.selectionStart ?? value.length;
            const end = target.selectionEnd ?? value.length;
            if (key === 'Backspace' && start > 0) {
              target.value = value.slice(0, start - 1) + value.slice(end);
              target.setSelectionRange && target.setSelectionRange(start - 1, start - 1);
              target.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'deleteContentBackward' }));
            } else if (key === 'Enter') {
              const form = target.form || (target.closest && target.closest('form'));
              if (form) {
                const submitter = Array.from(form.querySelectorAll(submitControlSelector)).find(visible) || null;
                if (form.requestSubmit) {
                  form.requestSubmit(submitter || undefined);
                } else {
                  const submitEvent = new Event('submit', { bubbles: true, cancelable: true });
                  if (form.dispatchEvent(submitEvent) && form.submit) form.submit();
                }
                result = 'submitted';
              } else {
                const submitter = Array.from(document.querySelectorAll(submitControlSelector)).find(visible);
                if (submitter) {
                  submitter.click();
                  result = 'clicked-submit';
                }
              }
            } else if (key === 'Tab') {
              const focusables = Array.from(document.querySelectorAll('a[href], button, input, textarea, select, [tabindex]:not([tabindex="-1"])'))
                .filter((el) => !el.disabled && el.offsetParent !== null);
              const index = focusables.indexOf(target);
              const next = focusables[(index + 1) % focusables.length];
              if (next) next.focus();
            }
          }
          dispatchKey('keyup');
          return result;
        })();
        """
    }

    private static func hotkeyJavaScript(combo: String) -> String {
        let combo = javaScriptStringLiteral(combo)
        return """
        (() => {
          const raw = \(combo);
          const parts = raw.split(/[+\\s,]+/).filter(Boolean);
          const key = parts.pop() || '';
          const lower = parts.map((p) => p.toLowerCase());
          const init = {
            key,
            code: key,
            bubbles: true,
            cancelable: true,
            metaKey: lower.includes('meta') || lower.includes('cmd') || lower.includes('command'),
            ctrlKey: lower.includes('ctrl') || lower.includes('control'),
            altKey: lower.includes('alt') || lower.includes('option'),
            shiftKey: lower.includes('shift')
          };
          const target = document.activeElement || document.body;
          target.dispatchEvent(new KeyboardEvent('keydown', init));
          target.dispatchEvent(new KeyboardEvent('keyup', init));
          if (init.metaKey && key.toLowerCase() === 'r') location.reload();
          if (init.metaKey && key.toLowerCase() === 'l') {
            window.__kookyAddressRequested = true;
          }
          return true;
        })();
        """
    }

    private static func scrollJavaScript(direction: String, amount: Double?) -> String {
        let normalized = direction.lowercased()
        let distance = amount ?? 0
        let fallback = "Math.max(window.innerHeight * 0.85, 400)"
        let dx: String
        let dy: String
        switch normalized {
        case "up":
            dx = "0"
            dy = distance > 0 ? "-\(distance)" : "-\(fallback)"
        case "left":
            dx = distance > 0 ? "-\(distance)" : "-\(fallback)"
            dy = "0"
        case "right":
            dx = distance > 0 ? "\(distance)" : fallback
            dy = "0"
        default:
            dx = "0"
            dy = distance > 0 ? "\(distance)" : fallback
        }
        return """
        (() => {
          const dx = \(dx);
          const dy = \(dy);
          const axis = Math.abs(dx) >= Math.abs(dy) ? 'x' : 'y';
          const delta = axis === 'x' ? dx : dy;
          const viewportWidth = Math.round(window.innerWidth || document.documentElement.clientWidth || 0);
          const viewportHeight = Math.round(window.innerHeight || document.documentElement.clientHeight || 0);
          const root = document.scrollingElement || document.documentElement || document.body;
          const clamp = (value, min, max) => Math.min(Math.max(value, min), max);
          const visibleArea = (el) => {
            const r = el.getBoundingClientRect();
            const w = Math.max(0, Math.min(r.right, viewportWidth) - Math.max(r.left, 0));
            const h = Math.max(0, Math.min(r.bottom, viewportHeight) - Math.max(r.top, 0));
            return w * h;
          };
          const metrics = (el) => {
            if (el === root || el === document.documentElement || el === document.body) {
              const scrollWidth = Math.round(root.scrollWidth || document.documentElement.scrollWidth || 0);
              const scrollHeight = Math.round(root.scrollHeight || document.documentElement.scrollHeight || 0);
              return {
                x: Math.round(window.scrollX || root.scrollLeft || 0),
                y: Math.round(window.scrollY || root.scrollTop || 0),
                maxX: Math.max(0, scrollWidth - viewportWidth),
                maxY: Math.max(0, scrollHeight - viewportHeight),
                viewportWidth,
                viewportHeight,
                scrollWidth,
                scrollHeight
              };
            }
            return {
              x: Math.round(el.scrollLeft || 0),
              y: Math.round(el.scrollTop || 0),
              maxX: Math.max(0, Math.round((el.scrollWidth || 0) - (el.clientWidth || 0))),
              maxY: Math.max(0, Math.round((el.scrollHeight || 0) - (el.clientHeight || 0))),
              viewportWidth: Math.round(el.clientWidth || 0),
              viewportHeight: Math.round(el.clientHeight || 0),
              scrollWidth: Math.round(el.scrollWidth || 0),
              scrollHeight: Math.round(el.scrollHeight || 0)
            };
          };
          const canScrollAxis = (el) => {
            if (!el) return false;
            const m = metrics(el);
            return axis === 'x' ? m.maxX > 1 : m.maxY > 1;
          };
          const canMoveAxis = (el) => {
            const m = metrics(el);
            const current = axis === 'x' ? m.x : m.y;
            const max = axis === 'x' ? m.maxX : m.maxY;
            return delta > 0 ? current < max - 1 : current > 1;
          };
          const descriptor = (el) => {
            if (el === root || el === document.documentElement || el === document.body) return 'window';
            const tag = (el.tagName || 'element').toLowerCase();
            const id = el.id ? '#' + el.id : '';
            const classes = typeof el.className === 'string'
              ? '.' + el.className.trim().split(/\\s+/).filter(Boolean).slice(0, 3).join('.')
              : '';
            return (tag + id + classes).slice(0, 160);
          };
          const addCandidate = (list, seen, el) => {
            for (let node = el; node && node.nodeType === 1; node = node.parentElement) {
              if (seen.has(node)) continue;
              seen.add(node);
              if (node === document.documentElement || node === document.body) continue;
              if (visibleArea(node) <= 0) continue;
              if (canScrollAxis(node)) list.push(node);
            }
          };
          const seen = new Set();
          const priority = [];
          addCandidate(priority, seen, document.activeElement);
          const points = [
            [viewportWidth * 0.50, viewportHeight * 0.50],
            [viewportWidth * 0.75, viewportHeight * 0.50],
            [viewportWidth * 0.50, viewportHeight * 0.70],
            [viewportWidth * 0.25, viewportHeight * 0.70],
            [viewportWidth * 0.90, viewportHeight * 0.50]
          ];
          for (const [x, y] of points) {
            for (const el of (document.elementsFromPoint ? document.elementsFromPoint(x, y) : [document.elementFromPoint(x, y)])) {
              addCandidate(priority, seen, el);
            }
          }
          const allScrollable = Array.from(document.querySelectorAll('*'))
            .filter((el) => !seen.has(el) && visibleArea(el) > 0 && canScrollAxis(el))
            .sort((a, b) => {
              const ma = metrics(a);
              const mb = metrics(b);
              const rangeA = axis === 'x' ? ma.maxX : ma.maxY;
              const rangeB = axis === 'x' ? mb.maxX : mb.maxY;
              return (rangeB - rangeA) || (visibleArea(b) - visibleArea(a));
            });
          const candidates = priority.concat(allScrollable);
          const movable = candidates.find(canMoveAxis);
          const target = movable || candidates[0] || root;
          const before = metrics(target);
          if (target === root || target === document.documentElement || target === document.body) {
            window.scrollBy({ left: dx, top: dy, behavior: 'auto' });
          } else {
            target.scrollLeft = clamp((target.scrollLeft || 0) + dx, 0, before.maxX);
            target.scrollTop = clamp((target.scrollTop || 0) + dy, 0, before.maxY);
          }
          const after = metrics(target);
          const movedX = after.x - before.x;
          const movedY = after.y - before.y;
          return [
            'ok scrolled \(normalized)',
            'target: ' + descriptor(target),
            'movedX: ' + movedX,
            'movedY: ' + movedY,
            'x: ' + after.x,
            'y: ' + after.y,
            'maxX: ' + after.maxX,
            'maxY: ' + after.maxY,
            'viewportWidth: ' + after.viewportWidth,
            'viewportHeight: ' + after.viewportHeight,
            'scrollWidth: ' + after.scrollWidth,
            'scrollHeight: ' + after.scrollHeight,
            'atLeft: ' + (after.x <= 1),
            'atRight: ' + (after.x >= after.maxX - 1),
            'atTop: ' + (after.y <= 1),
            'atBottom: ' + (after.y >= after.maxY - 1)
          ].join('\\n');
        })();
        """
    }

    private static func hoverJavaScript(id: String) -> String {
        let id = javaScriptStringLiteral(id)
        return """
        (() => {
          const target = window.__kookyElementById && window.__kookyElementById(\(id));
          if (!target) return false;
          target.scrollIntoView({ block: 'center', inline: 'center' });
          target.focus && target.focus();
          target.dispatchEvent(new MouseEvent('mouseover', { bubbles: true, cancelable: true, view: window }));
          target.dispatchEvent(new MouseEvent('mousemove', { bubbles: true, cancelable: true, view: window }));
          return true;
        })();
        """
    }

    private static func pageTextJavaScript() -> String {
        """
        (() => {
          const text = document.body ? (document.body.innerText || document.body.textContent || '') : '';
          return text.replace(/[ \\t]+\\n/g, '\\n').replace(/\\n{3,}/g, '\\n\\n').trim();
        })();
        """
    }

    private static func linksJavaScript() -> String {
        """
        (() => {
          \(domUtilityJavaScript())
          return window.__kookyVisibleElements('a[href]').map((el) => JSON.stringify({
            id: window.__kookyElementId(el),
            text: window.__kookyElementText(el),
            href: el.href,
            rect: window.__kookyRect(el)
          })).join('\\n');
        })();
        """
    }

    private static func elementsJavaScript() -> String {
        """
        (() => {
          \(domUtilityJavaScript())
          const selectors = [
            'a[href]', 'button', '[role="button"]', '[role="link"]',
            'input:not([type="hidden"])', 'textarea', 'select',
            '[contenteditable="true"]', '[role="textbox"]', 'summary', '[onclick]'
          ].join(',');
          return window.__kookyVisibleElements(selectors).slice(0, 300).map((el) => JSON.stringify({
            id: window.__kookyElementId(el),
            role: window.__kookyRole(el),
            text: window.__kookyElementText(el),
            value: 'value' in el ? String(el.value || '') : '',
            href: el.href || '',
            placeholder: el.getAttribute && (el.getAttribute('placeholder') || ''),
            rect: window.__kookyRect(el)
          })).join('\\n');
        })();
        """
    }

    private static func domUtilityJavaScript() -> String {
        """
        window.__kookyElementId = window.__kookyElementId || ((el) => {
          if (el.getAttribute && el.getAttribute('data-kooky-id')) return el.getAttribute('data-kooky-id');
          const all = Array.from(document.querySelectorAll('*'));
          const tag = (el.tagName || 'el').toLowerCase();
          const id = 'e' + (all.indexOf(el) + 1) + '-' + tag;
          try { el.setAttribute('data-kooky-id', id); } catch {}
          return id;
        });
        window.__kookyElementById = window.__kookyElementById || ((id) => {
          if (!id) return null;
          const direct = document.querySelector(`[data-kooky-id="${CSS.escape(id)}"]`);
          if (direct) return direct;
          const match = /^e(\\d+)-/.exec(id);
          if (!match) return null;
          return Array.from(document.querySelectorAll('*'))[Number(match[1]) - 1] || null;
        });
        window.__kookyRect = window.__kookyRect || ((el) => {
          const r = el.getBoundingClientRect();
          return { x: Math.round(r.x), y: Math.round(r.y), width: Math.round(r.width), height: Math.round(r.height) };
        });
        window.__kookyVisible = window.__kookyVisible || ((el) => {
          const style = window.getComputedStyle(el);
          if (style.visibility === 'hidden' || style.display === 'none' || Number(style.opacity) === 0) return false;
          const r = el.getBoundingClientRect();
          const vw = window.innerWidth || document.documentElement.clientWidth || 100000;
          const vh = window.innerHeight || document.documentElement.clientHeight || 100000;
          return r.width > 0 && r.height > 0 && r.bottom >= 0 && r.right >= 0 &&
            r.top <= vh && r.left <= vw;
        });
        window.__kookyElementText = window.__kookyElementText || ((el) => [
          el.innerText,
          el.textContent,
          el.getAttribute && el.getAttribute('aria-label'),
          el.getAttribute && el.getAttribute('title'),
          el.getAttribute && el.getAttribute('name')
        ].filter(Boolean).join(' ').replace(/\\s+/g, ' ').trim().slice(0, 240));
        window.__kookyRole = window.__kookyRole || ((el) => {
          if (el.getAttribute && el.getAttribute('role')) return el.getAttribute('role');
          const tag = (el.tagName || '').toLowerCase();
          if (tag === 'a') return 'link';
          if (tag === 'button') return 'button';
          if (tag === 'textarea') return 'textarea';
          if (tag === 'select') return 'select';
          if (tag === 'input') return el.getAttribute('type') || 'input';
          if (el.isContentEditable) return 'textbox';
          return tag;
        });
        window.__kookyVisibleElements = window.__kookyVisibleElements || ((selector) => {
          const seen = new Set();
          return Array.from(document.querySelectorAll(selector)).filter((el) => {
            if (seen.has(el) || !window.__kookyVisible(el)) return false;
            seen.add(el);
            window.__kookyElementId(el);
            return true;
          });
        });
        """
    }

    private static func javaScriptStringLiteral(_ value: String) -> String {
        guard
            let data = try? JSONSerialization.data(withJSONObject: [value]),
            let encoded = String(data: data, encoding: .utf8),
            encoded.count >= 2
        else { return "\"\"" }
        return String(encoded.dropFirst().dropLast())
    }
}

private extension String {
    func ensuringTrailingNewline() -> String {
        hasSuffix("\n") ? self : self + "\n"
    }

    func trimmedForCLI() -> String {
        trimmingCharacters(in: .whitespacesAndNewlines).ensuringTrailingNewline()
    }
}
