import UIKit
import WebKit

/// The site in a web view, which is every screen the app and the share sheet have. Pages reach the
/// phone through the `buddy` message handler: `postMessage({name, args})` returns a promise for
/// whatever `bridge` answers. Pages that can't load because there's no connection show the last
/// copy the web view kept.
@MainActor
final class WebShell: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandlerWithReply {
  typealias Bridge = @MainActor (_ name: String, _ args: [String: Any]) async throws -> Any?

  enum BridgeError: LocalizedError {
    case unknown(String)
    case missing(String)

    var errorDescription: String? {
      switch self {
      case .unknown(let name): return "The app doesn't know \(name)."
      case .missing(let field): return "Missing \(field)."
      }
    }
  }

  let webView: WKWebView
  var bridge: Bridge
  /// A buddy:// link tapped on a page.
  var handleAppURL: (URL) -> Void = { _ in }
  /// Anything that isn't this site: another site, tel:, maps, a link meant for a new window.
  var openExternally: (URL) -> Void = { _ in }
  /// A page bounced to the site's own login, so the web session needs minting again.
  var sessionExpired: () -> Void = {}
  /// A page couldn't load and the web view had no copy of it either.
  var loadFailed: () -> Void = {}
  /// A page's own confirm(). Links with data-confirm already ask in the site's modal; this is for
  /// the few scripts that call confirm() themselves.
  var confirmPanel: (String) async -> Bool = { _ in true }

  private(set) var lastPath: String?
  /// Whether the web view already holds the site's login cookie. Remembered across launches, so a
  /// cold start (even after a force close, even with no signal) opens the page straight from the
  /// Buddy page's service worker rather than through a sign-in request that can't load offline.
  ///
  /// Kept per process: the share sheet has a web view and cookies of its own, so the app being
  /// signed in says nothing about it.
  private var hasSession: Bool {
    get { SharedStore.defaults.bool(forKey: Self.sessionKey) }
    set { SharedStore.defaults.set(newValue, forKey: Self.sessionKey) }
  }

  private static var sessionKey: String {
    let bundle = Bundle.main.bundleIdentifier ?? ""
    return bundle.hasSuffix(".share") ? "\(SharedStore.Key.webSession).share" : SharedStore.Key.webSession
  }
  private var retriedFromCache: Set<URL> = []
  private let focusPolicy = FocusPolicy()

  init(bridge: @escaping Bridge) {
    self.bridge = bridge
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .default()
    // Service workers (the Buddy page's offline copy of itself) only run in an app's web view on
    // its app-bound domains (WKAppBoundDomains in Info.plist). Limiting navigation to them is what
    // switches that on, so it's only done when the server is one of them; a dev server on a bare
    // IP still loads, without the offline copy.
    configuration.limitsNavigationsToAppBoundDomains = Self.isAppBound(BuddyConfig.serverURL.host)
    configuration.allowsInlineMediaPlayback = true
    configuration.applicationNameForUserAgent = "BuddyiOS"
    webView = WKWebView(frame: .zero, configuration: configuration)
    super.init()
    configuration.userContentController.addScriptMessageHandler(WeakHandler(self), contentWorld: .page, name: "buddy")
    refreshNativeInfo()
    webView.navigationDelegate = self
    webView.uiDelegate = self
    webView.allowsBackForwardNavigationGestures = true
    let setInputDelegate = NSSelectorFromString("_setInputDelegate:")
    if webView.responds(to: setInputDelegate) { webView.perform(setInputDelegate, with: focusPolicy) }
    webView.isOpaque = false
    webView.scrollView.refreshControl = UIRefreshControl()
    webView.scrollView.refreshControl?.addTarget(self, action: #selector(refresh(_:)), for: .valueChanged)
  }

  /// What a page can read about the app before its own scripts run: which phone this is and which
  /// features are on, so it can show what only the app can do.
  func refreshNativeInfo() {
    let info: [String: Any] = [
      "platform": "ios",
      "deviceId": Session.current?.deviceId ?? NSNull(),
      "features": Feature.enabled.map(\.rawValue).sorted(),
    ]
    let json = (try? JSONSerialization.data(withJSONObject: info)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    let controller = webView.configuration.userContentController
    controller.removeAllUserScripts()
    // The class is set before the page draws, so what a page shows only outside the app never
    // flashes up inside it.
    let source = "window.BuddyNative = \(json); document.documentElement.classList.add('buddy-native');"
    controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
  }

  /// A page on the site, signed in with the device token the first time so every page after that
  /// is the ordinary site session.
  func load(_ path: String) {
    lastPath = path
    if hasSession, let url = URL(string: path, relativeTo: BuddyConfig.serverURL) {
      webView.load(URLRequest(url: url))
      return
    }
    guard var request = try? APIClient.shared.request("GET", "api/ios/web_session", query: ["to": path]) else { return }
    request.setValue("text/html", forHTTPHeaderField: "Accept")
    hasSession = true
    webView.load(request)
  }

  /// A page that needs no sign-in, such as the login page itself.
  func loadPublic(_ path: String, query: [String: String] = [:]) {
    hasSession = false
    lastPath = nil
    var components = URLComponents(url: BuddyConfig.serverURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
    components?.queryItems = query.isEmpty ? nil : query.map { URLQueryItem(name: $0.key, value: $0.value) }
    guard let url = components?.url else { return }
    webView.load(URLRequest(url: url))
  }

  /// The quick prompt, from the copy kept on the phone when there is one: nothing to fetch, so
  /// the field is ready as soon as the app is.
  func loadCompose(_ path: String) {
    guard let html = SharedStore.defaults.string(forKey: SharedStore.Key.composePage),
          let url = URL(string: path, relativeTo: BuddyConfig.serverURL)?.absoluteURL else {
      load(path)
      return
    }
    lastPath = path
    webView.loadHTMLString(html, baseURL: url)
  }

  /// Fetched each time the app comes to the front, so a change to the page is in the next copy.
  static func refreshComposePage() async {
    guard var request = try? APIClient.shared.request("GET", "app/compose") else { return }
    request.setValue("text/html", forHTTPHeaderField: "Accept")
    guard let data = try? await APIClient.shared.send(request),
          let html = String(data: data, encoding: .utf8),
          html.contains("<textarea name=\"text\"") else { return }
    SharedStore.defaults.set(html, forKey: SharedStore.Key.composePage)
  }

  func forgetSession() {
    hasSession = false
  }

  /// A notice in the site's own flash banner on whatever page is showing.
  func flash(_ message: String, alert: Bool = false) {
    let json = (try? JSONSerialization.data(withJSONObject: [message])).flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
    let function = alert ? "addFlashAlert" : "addFlashNotice"
    webView.evaluateJavaScript("typeof \(function) === 'function' && \(function)(...\(json))")
  }

  /// Tells the page something changed on the phone, e.g. `buddy:outbox`.
  func emit(_ event: String) {
    webView.evaluateJavaScript("window.dispatchEvent(new CustomEvent('\(event)'))")
  }

  static func isAppBound(_ host: String?) -> Bool {
    guard let host, let domains = Bundle.main.object(forInfoDictionaryKey: "WKAppBoundDomains") as? [String] else { return false }
    return domains.contains(host)
  }


  @objc private func refresh(_ control: UIRefreshControl) {
    webView.reload()
    control.endRefreshing()
  }

  // MARK: Bridge

  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) async -> (Any?, String?) {
    guard let body = message.body as? [String: Any], let name = body["name"] as? String else {
      return (nil, "A message needs a name.")
    }
    do {
      let reply = try await bridge(name, body["args"] as? [String: Any] ?? [:])
      return (reply ?? NSNull(), nil)
    } catch {
      return (nil, error.localizedDescription)
    }
  }

  /// Turns anything Encodable into what a page receives: plain dictionaries and arrays.
  static func plain<T: Encodable>(_ value: T) -> Any {
    guard let data = try? SharedStore.encoder.encode(value),
          let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return NSNull() }
    return object
  }

  // MARK: Navigation

  /// Every page change in the web view, whether a tap, a form, a page's own script or a redirect:
  /// the app's own pages load here, and anything else opens where it lives. A redirect is checked
  /// too, so an app page that forwards to another part of the site still leaves the app.
  func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
    guard let url = action.request.url else { return .allow }
    if url.scheme == BuddyConfig.urlScheme {
      handleAppURL(url)
      return .cancel
    }
    if ["tel", "sms", "mailto", "maps"].contains(url.scheme ?? "") {
      openExternally(url)
      return .cancel
    }
    guard ["http", "https"].contains(url.scheme ?? ""), action.targetFrame?.isMainFrame != false else { return .allow }
    if Self.isSiteLogin(url) {
      // The site's own login means the web session ran out; the device token mints a new one.
      if Session.isSignedIn {
        hasSession = false
        sessionExpired()
      }
      return .cancel
    }
    if Self.opensInApp(url) || [.backForward, .reload].contains(action.navigationType) { return .allow }
    openExternally(url)
    return .cancel
  }

  /// This site, on its own domain or one of its subdomains (Buddy, Board, Kiosk and the rest).
  nonisolated static func isSite(_ url: URL) -> Bool {
    guard let host = url.host, let serverHost = BuddyConfig.serverURL.host else { return false }
    return host == serverHost || host.hasSuffix(".\(serverHost)")
  }

  /// Buddy itself: the chat at the root of its subdomain, or `/byte`, which redirects there. Board,
  /// Kiosk and every other path on that subdomain are apps of their own.
  nonisolated static func isBuddy(_ url: URL) -> Bool {
    guard isSite(url), let host = url.host else { return false }
    if host == "byte.\(BuddyConfig.serverURL.host ?? "")", url.path.isEmpty || url.path == "/" { return true }
    return url.path == "/byte"
  }

  /// The app's own screens: Buddy, and the app's login, settings, hot links and queue. They're
  /// served on either host, since a link on the Buddy page resolves against its subdomain.
  nonisolated static func isAppPage(_ url: URL) -> Bool {
    guard isSite(url) else { return false }
    if isBuddy(url) { return true }
    let path = url.path
    return path.hasPrefix("/app/") || path == "/account/app_devices" || path.hasPrefix("/account/app_devices/")
      || path.hasPrefix("/api/ios/")
  }

  /// Whether a page loads in this web view: an app page always, the rest of the site only when the
  /// phone is set to open links in the app. Every other page opens in its own app, or Safari.
  nonisolated static func opensInApp(_ url: URL) -> Bool {
    isAppPage(url) || (isSite(url) && Preferences.current.openLinksInApp)
  }

  nonisolated static func isSiteLogin(_ url: URL) -> Bool {
    isSite(url) && url.path == "/login"
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    if let url = webView.url { retriedFromCache.remove(url) }
  }

  /// No connection: show the copy the web view kept from last time, once, before giving up.
  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    let nsError = error as NSError
    guard nsError.domain == NSURLErrorDomain,
          let failed = nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL else { return }
    guard !retriedFromCache.contains(failed) else {
      loadFailed()
      return
    }
    retriedFromCache.insert(failed)
    webView.load(URLRequest(url: failed, cachePolicy: .returnCacheDataDontLoad))
  }

  func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
    await confirmPanel(message)
  }

  /// The page's alert() is already the site's flash inside the app; this catches one raised
  /// before the page's scripts have loaded.
  func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
    flash(message)
  }

  /// A link meant for a new window (target="_blank", or the Buddy page's window.open, which it uses
  /// for every link): one of the app's own screens opens here, anything else where it lives.
  func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
    guard let url = navigationAction.request.url else { return nil }
    if Self.opensInApp(url) {
      webView.load(navigationAction.request)
    } else {
      openExternally(url)
    }
    return nil
  }
}

/// Lets the quick prompt's field bring the keyboard up as the page opens. WebKit only shows the
/// keyboard for a field that was tapped, unless the web view's input delegate (`_WKInputDelegate`,
/// which isn't public) allows a focus from the page's own script.
@MainActor
private final class FocusPolicy: NSObject {
  /// Answers with a `_WKFocusStartsInputSessionPolicy`: 0 decides as usual, 1 allows.
  @objc(_webView:decidePolicyForFocusedElement:)
  func decidePolicy(_ webView: WKWebView, focusedElement: AnyObject) -> Int {
    webView.url?.path == "/app/compose" ? 1 : 0
  }
}

/// The content controller holds its handlers strongly; this keeps that from holding the shell.
private final class WeakHandler: NSObject, WKScriptMessageHandlerWithReply {
  weak var target: WebShell?

  init(_ target: WebShell) {
    self.target = target
  }

  @MainActor
  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) async -> (Any?, String?) {
    guard let target else { return (nil, "The page outlived the app.") }
    return await target.userContentController(userContentController, didReceive: message)
  }
}
