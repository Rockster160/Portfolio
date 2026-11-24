import SwiftUI
import UserNotifications
import WidgetKit

@main
struct BuddyApp: App {
  @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
  @StateObject private var model = AppModel.shared
  @Environment(\.scenePhase) private var scenePhase

  var body: some Scene {
    WindowGroup {
      RootView()
        .environmentObject(model)
        .onOpenURL { model.handle(url: $0) }
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
          if let url = activity.webpageURL { model.handle(url: url) }
        }
    }
    .onChange(of: scenePhase) { _, phase in
      switch phase {
      case .active: model.didBecomeActive()
      case .background:
        Outbox.releaseHeld()
        BackgroundWork.schedule()
      default: break
      }
    }
  }
}

/// App-wide state: who's signed in, and the one web view every screen is shown in.
@MainActor
final class AppModel: ObservableObject {
  static let shared = AppModel()

  let shell: WebShell
  let progress: PageProgress
  @Published private(set) var signedIn = Session.isSignedIn
  var route: DeepLink.Route? {
    didSet { if let route { apply(route) } }
  }

  var isShowingBuddy: Bool {
    shell.webView.url.map(WebShell.isBuddy) ?? false
  }

  init() {
    shell = WebShell { name, args in try await AppBridge.handle(name, args) }
    progress = PageProgress(webView: shell.webView)
    shell.handleAppURL = { AppModel.shared.handle(url: $0) }
    shell.openExternally = { UIApplication.shared.open($0) }
    shell.sessionExpired = { AppModel.shared.reloadPage() }
    shell.confirmPanel = { await SiteDialog.confirm($0) }
    NotificationCenter.default.addObserver(forName: .buddyUnauthorized, object: nil, queue: .main) { _ in
      Task { @MainActor in AppModel.shared.handleUnauthorized() }
    }
    NotificationCenter.default.addObserver(forName: .buddyOutboxChanged, object: nil, queue: .main) { _ in
      Task { @MainActor in AppModel.shared.shell.emit("buddy:outbox") }
    }
    if signedIn {
      shell.load(Self.buddyPath())
    } else {
      showLogin()
    }
  }

  func didBecomeActive() {
    guard signedIn else { return }
    Outbox.holdByteCopies()
    // Opening the app clears the icon number, always; the server's next count repaints it.
    UNUserNotificationCenter.current().setBadgeCount(0)
    Task {
      await QuickActions.performPending()
      _ = try? await Catalog.refresh()
      BuddyShortcuts.updateAppShortcutParameters()
      await DeviceSync.push()
      await FeatureManager.shared.syncAll(reason: "foreground")
      WidgetCenter.shared.reloadAllTimelines()
      await WebShell.refreshComposePage()
    }
  }

  /// The login page, carrying what this phone is so the device it signs in as is named for it.
  func showLogin() {
    let device = UIDevice.current
    shell.refreshNativeInfo()
    shell.loadPublic("app/login", query: [
      "device[name]": device.name,
      "device[model]": device.model,
      "device[os_version]": device.systemVersion,
      "device[app_version]": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1",
      "device[timezone]": TimeZone.current.identifier,
    ])
  }

  func signedInNow() {
    signedIn = true
    shell.refreshNativeInfo()
    PushService.shared.register()
    shell.load(Self.buddyPath())
    didBecomeActive()
  }

  func signOut() async {
    _ = try? await APIClient.shared.delete("api/ios/session")
    Session.signOut()
    signedIn = false
    shell.forgetSession()
    WidgetCenter.shared.reloadAllTimelines()
    showLogin()
  }

  func reloadPage() {
    shell.load(shell.lastPath ?? Self.buddyPath())
  }

  private func handleUnauthorized() {
    guard signedIn else { return }
    Session.signOut()
    signedIn = false
    shell.forgetSession()
    showLogin()
  }

  func handle(url: URL) {
    guard let route = DeepLink.parse(url) else {
      UIApplication.shared.open(url)
      return
    }
    self.route = route
  }

  func open(urlString: String) {
    if let url = URL(string: urlString), url.scheme != nil {
      handle(url: url)
    } else {
      route = .web(path: urlString)
    }
  }

  private func apply(_ route: DeepLink.Route) {
    guard signedIn else { return }
    switch route {
    case .home:
      shell.load(Self.buddyPath())
    case .buddy(let id):
      shell.load(Self.buddyPath(conversationId: id))
    case .web(let path):
      // Another page opens where it lives, unless this phone is set to keep pages in the app.
      if let url = URL(string: path, relativeTo: BuddyConfig.serverURL)?.absoluteURL, !WebShell.opensInApp(url) {
        UIApplication.shared.open(url)
      } else {
        shell.load(path)
      }
    case .checkIn(let id):
      Task { await openCheckIn(id: id) }
    case .compose(let action):
      shell.loadCompose(Self.composePath(action))
    case .queue:
      shell.load("/app/commands")
    case .settings:
      shell.load("/app/settings")
    case .feature(let feature):
      shell.load("/app/settings#feature-\(feature.rawValue)")
    case .hotLink(let id):
      if let link = HotLink.all.first(where: { $0.id == id }) {
        Task { await run(link.pressed, source: "hot_link") }
      }
    }
  }

  /// The Buddy page on its own subdomain, asked for directly: `/byte` on the main site is only a
  /// redirect there, and with no signal a redirect can't be followed, while the Buddy page's
  /// service worker answers for its own address straight from the phone.
  static func buddyPath(conversationId: Int? = nil) -> String {
    let server = BuddyConfig.serverURL
    let query = conversationId.map { "?conversation_id=\($0)" } ?? ""
    guard let host = server.host, host.rangeOfCharacter(from: .letters) != nil,
          var components = URLComponents(url: server, resolvingAgainstBaseURL: false) else { return "/byte\(query)" }
    components.host = "byte.\(host)"
    components.path = "/"
    return (components.string ?? "/byte") + query
  }

  /// The quick prompt page for something that asks before it sends, e.g. "Take me to" + typed.
  static func composePath(_ action: ButtonAction) -> String {
    var components = URLComponents()
    components.path = "/app/compose"
    var items = [URLQueryItem(name: "send_as", value: (action.sendAs ?? .buddy).rawValue)]
    if let prefix = action.prefix { items.append(URLQueryItem(name: "prefix", value: prefix)) }
    if let placeholder = action.placeholder { items.append(URLQueryItem(name: "placeholder", value: placeholder)) }
    if let inline = action.inline { items.append(URLQueryItem(name: "inline", value: String(inline))) }
    if let data = action.data, let json = try? SharedStore.encoder.encode(data) {
      items.append(URLQueryItem(name: "data", value: String(data: json, encoding: .utf8)))
    }
    components.queryItems = items
    return components.string ?? "/app/compose"
  }

  /// A check-in opens the oldest unanswered prompt, or the mood check-in when nothing's waiting.
  func openCheckIn(id: String?) async {
    if let id, !id.isEmpty {
      route = .web(path: "/prompts/\(id)")
      return
    }
    struct CheckIns: Decodable {
      struct Prompt: Decodable {
        var id: Int
        var title: String?
        var url: String?
      }
      var prompts: [Prompt]
      var moodUrl: String?
    }
    if let reply = try? await APIClient.shared.get("api/ios/check_ins", as: CheckIns.self) {
      if let first = reply.prompts.first {
        route = .web(path: first.url ?? "/prompts/\(first.id)")
      } else {
        route = .web(path: reply.moodUrl ?? "/prompts")
      }
    } else {
      route = .web(path: "/prompts")
    }
  }

  func run(_ action: ButtonAction, source: String) async {
    switch await ActionRunner.run(action, source: source) {
    case .queued(let item):
      if Preferences.current.commandsShowConfirmations {
        shell.flash(Outbox.items.contains(where: { $0.id == item.id }) ? "Queued, sends when it can" : "Sent")
      }
    case .replied(let text):
      shell.flash(text)
    case .open(let url):
      handle(url: url)
    }
  }
}
