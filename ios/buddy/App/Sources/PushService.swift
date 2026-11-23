import ActivityKit
import EventKit
import UIKit
import UserNotifications
import WidgetKit

/// Native push: asks permission, hands the token to the server, and carries out the silent
/// instructions the server sends (dismiss, badge, timers, widget refresh).
final class PushService {
  static let shared = PushService()

  var environment: String {
    #if DEBUG
    return "development"
    #else
    return "production"
    #endif
  }

  func enable() async -> Bool {
    let center = UNUserNotificationCenter.current()
    let options: UNAuthorizationOptions = [.alert, .badge, .sound, .providesAppNotificationSettings]
    let granted = (try? await center.requestAuthorization(options: options)) ?? false
    await MainActor.run { UIApplication.shared.registerForRemoteNotifications() }
    return granted
  }

  /// A push token needs no permission, only alerts do, so every signed-in phone has one: the site
  /// reaches it with silent pushes (settings changed, a task to run) even with notifications off.
  func register() {
    Task { @MainActor in UIApplication.shared.registerForRemoteNotifications() }
  }

  func didRegister(_ token: Data) {
    let hex = token.map { String(format: "%02x", $0) }.joined()
    SharedStore.defaults.set(hex, forKey: SharedStore.Key.apnsToken)
    Task { await DeviceSync.push() }
  }

  /// The silent half of the server's push contract.
  func handleBackground(_ info: [AnyHashable: Any]) async {
    let preferences = Preferences.current
    if info["clear_all"] as? Bool == true, preferences.pushBadges {
      UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }
    if let tags = info["remove_tags"] as? [String], !tags.isEmpty, preferences.pushBadges {
      await NotificationLedger.remove(tags: Set(tags))
    }
    if let conversation = info["remove_conversation"], preferences.pushBadges {
      let id = "\(conversation)"
      let center = UNUserNotificationCenter.current()
      let read = await center.deliveredNotifications().filter { notification in
        notification.request.content.userInfo["conversation_id"].map { "\($0)" } == id
      }
      center.removeDeliveredNotifications(withIdentifiers: read.map(\.request.identifier))
    }
    if let badge = info["badge"] as? Int, preferences.pushBadges {
      try? await UNUserNotificationCenter.current().setBadgeCount(badge)
    }
    if let timer = info["timer"] as? [String: Any],
       let data = try? JSONSerialization.data(withJSONObject: timer),
       let decoded = try? SharedStore.decoder.decode(TimerData.self, from: data) {
      await TimerSync.apply(decoded)
    }
    if info["timers_changed"] as? Bool == true {
      await TimerSync.reconcile()
    }
    if info["reload_widgets"] as? Bool == true {
      WidgetCenter.shared.reloadAllTimelines()
    }
    if info["refresh_catalog"] as? Bool == true {
      _ = try? await Catalog.refresh()
    }
    if info["sync"] as? Bool == true {
      await FeatureManager.shared.syncAll(reason: "push")
    }
    if info["settings"] as? Bool == true {
      await DeviceSync.push()
    }
    if let task = info["device_task"] as? String {
      await FeatureManager.shared.run(task: task)
    }
    await Outbox.flush()
  }
}

/// Keeps the server's copy of this device current (tokens, what iOS allows, the calendars there
/// are to pick from) and takes back the settings chosen on the site.
enum DeviceSync {
  struct Body: Encodable {
    var name: String
    var model: String
    var osVersion: String
    var appVersion: String
    var timezone: String
    var apnsToken: String?
    var apnsEnvironment: String
    var pushToStartTokens: [String: String]
    var widgetPushToken: String?
    var permissions: [String: String]
    var sources: Sources
    var turnOn: [String]
  }

  struct Sources: Encodable {
    var calendars: [Source]
    var reminderLists: [Source]
  }

  struct Source: Encodable {
    var id: String
    var title: String
    var color: String
  }

  struct Settings: Decodable {
    var features: [String]
    var preferences: Preferences
    var hotLinks: [HotLink]
    var darkMode: Bool?
  }

  static func push(turnOn: [Feature] = []) async {
    guard Session.isSignedIn else { return }
    let (deviceName, model, osVersion) = await MainActor.run {
      (UIDevice.current.name, UIDevice.current.model, UIDevice.current.systemVersion)
    }
    let body = Body(
      name: Session.current?.deviceName ?? deviceName,
      model: model,
      osVersion: osVersion,
      appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1",
      timezone: TimeZone.current.identifier,
      apnsToken: SharedStore.defaults.string(forKey: SharedStore.Key.apnsToken),
      apnsEnvironment: PushService.shared.environment,
      pushToStartTokens: SharedStore.load([String: String].self, key: "push_to_start_tokens") ?? [:],
      widgetPushToken: SharedStore.defaults.string(forKey: "widget_push_token"),
      permissions: await Permissions.all(),
      sources: await MainActor.run { sources() },
      turnOn: turnOn.map(\.rawValue),
    )
    do {
      let settings = try await APIClient.shared.patch("api/ios/device", body: body, as: Settings.self)
      await apply(settings)
    } catch {
      ActivityLog.add("Device sync failed: \(error.localizedDescription)")
    }
  }

  @MainActor
  private static func apply(_ settings: Settings) {
    if let darkMode = settings.darkMode {
      SharedStore.defaults.set(darkMode, forKey: SharedStore.Key.darkMode)
    }
    FeatureManager.shared.apply(
      features: Set(settings.features.compactMap(Feature.init(rawValue:))),
      preferences: settings.preferences,
      hotLinks: settings.hotLinks,
    )
    AppModel.shared.shell.refreshNativeInfo()
  }

  /// The calendars and reminder lists on the phone, so the site can offer them by name.
  @MainActor
  private static func sources() -> Sources {
    func list(_ entity: EKEntityType) -> [Source] {
      let allowed = EKEventStore.authorizationStatus(for: entity) == .fullAccess
      guard allowed else { return [] }
      return NativeSync.shared.events.calendars(for: entity).map { calendar in
        Source(id: calendar.calendarIdentifier, title: calendar.title, color: hex(calendar.cgColor))
      }
    }
    return Sources(calendars: list(.event), reminderLists: list(.reminder))
  }

  private static func hex(_ color: CGColor?) -> String {
    guard let components = color?.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components,
          components.count >= 3 else { return "#8e8e93" }
    return String(format: "#%02x%02x%02x", Int(components[0] * 255), Int(components[1] * 255), Int(components[2] * 255))
  }
}
