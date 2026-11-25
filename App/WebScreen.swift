import SwiftUI
import UIKit
import WebKit

struct WebScreen: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.websiteDataStore = .default()   // keeps the login cookie between launches
        config.applicationNameForUserAgent = "StrapifyMessengerApp/1.0"
        let controller = WKUserContentController()
        // The saved Apple token is on the page before its scripts run; native-bridge.js
        // registers it (POST /api/v1/push/subscribe with an apns: endpoint).
        if let token = UserDefaults.standard.string(forKey: Config.tokenKey) {
            let source = "window.__nativePushToken = \(Coordinator.jsString(token));"
            controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart,
                                                  forMainFrameOnly: true))
        }
        config.userContentController = controller

        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        web.allowsBackForwardNavigationGestures = true
        // Lay out exactly like the Home Screen PWA: the page fills the whole screen and places
        // itself around the notch, home bar and the Duo's fold/side edges with its own
        // viewport-fit=cover + env(safe-area-inset-*) CSS. Letting UIKit also inset the scroll
        // view gave double (or missing) gaps.
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.scrollView.bounces = false          // the messenger scrolls its own panes, like the PWA
        web.isOpaque = false
        web.backgroundColor = .systemBackground
        web.scrollView.backgroundColor = .systemBackground
        context.coordinator.attach(web)

        let first = AppDelegate.pendingURL ?? Config.start
        AppDelegate.pendingURL = nil
        web.load(URLRequest(url: first))
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private weak var web: WKWebView?
        private var observers: [NSObjectProtocol] = []

        /// A Swift string as a JavaScript string literal (quotes and escapes handled by JSON).
        static func jsString(_ value: String) -> String {
            guard let data = try? JSONSerialization.data(withJSONObject: [value]),
                  let array = String(data: data, encoding: .utf8) else { return "\"\"" }
            return String(array.dropFirst().dropLast())
        }

        func attach(_ web: WKWebView) {
            self.web = web
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: .openMessengerURL, object: nil, queue: .main) { [weak self] note in
                guard let url = note.userInfo?["url"] as? URL else { return }
                AppDelegate.pendingURL = nil
                self?.tappedAt = Date()     // this tap owns the screen: no foreground reload over it
                self?.web?.load(URLRequest(url: url))
            })
            observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                self?.backgroundedAt = Date()
            })
            observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                // A notification tap is delivered just after this; give it a moment to claim the screen.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self?.checkOnForeground() }
            })
            observers.append(center.addObserver(forName: .apnsToken, object: nil, queue: .main) { [weak self] note in
                guard let token = note.userInfo?["token"] as? String else { return }
                let js = "window.__nativePushToken = \(Coordinator.jsString(token));"
                    + "window.strapifyNativePushToken && window.strapifyNativePushToken(window.__nativePushToken);"
                self?.web?.evaluateJavaScript(js, completionHandler: nil)
            })
        }

        deinit {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
        }

        /// Own pages stay in the app; Shopify, the CRM, tracking links etc. open in Safari.
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else { return decisionHandler(.allow) }
            let scheme = url.scheme?.lowercased() ?? ""
            if ["about", "blob", "data"].contains(scheme) { return decisionHandler(.allow) }
            let web = scheme == "http" || scheme == "https"
            let mainFrame = navigationAction.targetFrame?.isMainFrame ?? false
            // Our own pages, and anything loading inside a frame (link previews, PDFs), stay put.
            if web && (Config.isOwnHost(url) || !mainFrame) && navigationAction.targetFrame != nil {
                return decisionHandler(.allow)
            }
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
        }

        /// window.open / target=_blank: our own pages open in place, everything else in Safari.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url {
                if Config.isOwnHost(url) {
                    webView.load(URLRequest(url: url))
                } else {
                    UIApplication.shared.open(url)
                }
            }
            return nil
        }

        /// Huddles: grant camera/microphone to our own site without a second web prompt
        /// (iOS still asks once for the app itself).
        func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                     initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                     decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) {
            decisionHandler(origin.host.lowercased() == Config.ownHost ? .grant : .prompt)
        }

        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) {
            present(message, ok: { completionHandler() }, cancel: nil)
        }

        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) {
            present(message, ok: { completionHandler(true) }, cancel: { completionHandler(false) })
        }

        /// iOS can kill the web content process in the background. After that the web view's
        /// url is often nil, so reload() does nothing and the screen stays white: load the
        /// last page we know about instead.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            reloadFresh()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if let url = webView.url, Config.isOwnHost(url) { lastURL = Self.withoutMessage(url) }
        }

        /// A notification link carries &m=<message id> so the tap lands on that message. Kept as
        /// "the page to come back to", it made every later reload jump back to that OLD message.
        /// Remember the conversation only (the page itself also drops m once it has jumped).
        static func withoutMessage(_ url: URL) -> URL {
            guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
            let kept = (parts.queryItems ?? []).filter { $0.name != "m" }
            parts.queryItems = kept.isEmpty ? nil : kept
            return parts.url ?? url
        }

        private var lastURL: URL?
        private var backgroundedAt: Date?
        private var tappedAt: Date?
        private static let staleAfter: TimeInterval = 5 * 60

        private func reloadFresh() {
            guard let web else { return }
            // Prefer where the page is NOW (it rewrites its address to ?c=<open chat> as you move).
            let here = web.url.flatMap { Config.isOwnHost($0) ? Self.withoutMessage($0) : nil }
            web.load(URLRequest(url: here ?? lastURL ?? Config.start))
        }

        /// Back in front: if the page was killed, is blank, or has sat long enough that its
        /// live connection has likely dropped, load it again.
        private func checkOnForeground() {
            guard let web else { return }
            let away = backgroundedAt.map { Date().timeIntervalSince($0) } ?? 0
            backgroundedAt = nil
            if let tappedAt, Date().timeIntervalSince(tappedAt) < 5 { return }   // a tap already loaded fresh
            if web.url == nil || away > Self.staleAfter { return reloadFresh() }
            var answered = false
            web.evaluateJavaScript("document.body ? document.body.children.length : 0") { [weak self] result, error in
                answered = true
                let children = (result as? Int) ?? 0
                if error != nil || children == 0 { self?.reloadFresh() }
            }
            // A hung content process never answers.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                if !answered { self?.reloadFresh() }
            }
        }

        private func present(_ message: String, ok: @escaping () -> Void, cancel: (() -> Void)?) {
            guard let root = web?.window?.rootViewController else {
                ok()
                return
            }
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            if let cancel {
                alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in cancel() })
            }
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in ok() })
            var top = root
            while let next = top.presentedViewController { top = next }
            top.present(alert, animated: true)
        }
    }
}
