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
        let refresh = UIRefreshControl()
        refresh.addTarget(context.coordinator, action: #selector(Coordinator.reload(_:)), for: .valueChanged)
        web.scrollView.refreshControl = refresh
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
                self?.web?.load(URLRequest(url: url))
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

        @objc func reload(_ sender: UIRefreshControl) {
            web?.reload()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { sender.endRefreshing() }
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

        /// iOS can kill the web content process in the background; come back to a live page.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            webView.reload()
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
