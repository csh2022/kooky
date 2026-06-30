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

    func fill(field: String, text: String) {
        let trimmed = field.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        evaluate(Self.fillJavaScript(field: trimmed, text: text))
    }

    func type(text: String) {
        guard !text.isEmpty else { return }
        evaluate(Self.typeJavaScript(text: text))
    }

    func press(key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        evaluate(Self.pressJavaScript(key: trimmed))
    }

    func scroll(direction: String, amount: Double?) {
        evaluate(Self.scrollJavaScript(direction: direction, amount: amount))
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
          target.scrollIntoView({ block: 'center', inline: 'center' });
          target.focus();
          if (target.isContentEditable) {
            target.textContent = value;
          } else {
            target.value = value;
          }
          target.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: value }));
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
          const eventInit = { key, code: key, bubbles: true, cancelable: true };
          target.dispatchEvent(new KeyboardEvent('keydown', eventInit));
          if ('value' in target) {
            const value = target.value ?? '';
            const start = target.selectionStart ?? value.length;
            const end = target.selectionEnd ?? value.length;
            if (key === 'Backspace' && start > 0) {
              target.value = value.slice(0, start - 1) + value.slice(end);
              target.setSelectionRange && target.setSelectionRange(start - 1, start - 1);
              target.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'deleteContentBackward' }));
            } else if (key === 'Enter') {
              const form = target.form;
              if (form && form.requestSubmit) form.requestSubmit();
            } else if (key === 'Tab') {
              const focusables = Array.from(document.querySelectorAll('a[href], button, input, textarea, select, [tabindex]:not([tabindex="-1"])'))
                .filter((el) => !el.disabled && el.offsetParent !== null);
              const index = focusables.indexOf(target);
              const next = focusables[(index + 1) % focusables.length];
              if (next) next.focus();
            }
          }
          target.dispatchEvent(new KeyboardEvent('keyup', eventInit));
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
          window.scrollBy({ left: \(dx), top: \(dy), behavior: 'smooth' });
          return true;
        })();
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
