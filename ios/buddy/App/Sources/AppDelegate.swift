import UIKit
import UserNotifications
import WidgetKit

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
  func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
    UNUserNotificationCenter.current().delegate = self
    UNUserNotificationCenter.current().setNotificationCategories(NotificationActions.baseCategories)
    BackgroundWork.register()
    FeatureManager.shared.resumeEnabledFeatures(launchOptions: launchOptions)
    if Session.isSignedIn { PushService.shared.register() }
    return true
  }

  // MARK: Push registration

  func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
    PushService.shared.didRegister(deviceToken)
  }

  func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
    ActivityLog.add("Push registration failed: \(error.localizedDescription)")
  }

  /// Silent pushes: dismissals, badge corrections, timers to ring, widgets to refresh, and a nudge
  /// to send anything still queued.
  func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
    Task {
      await PushService.shared.handleBackground(userInfo)
      completionHandler(.newData)
    }
  }

  func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
    BackgroundUploader.shared.reconnect(identifier: identifier, completion: completionHandler)
  }

  // MARK: Quick actions

  func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
    if let item = options.shortcutItem { QuickActions.pending = item }
    let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
    configuration.delegateClass = SceneDelegate.self
    return configuration
  }

  // MARK: Notifications

  func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
    let info = notification.request.content.userInfo
    NotificationLedger.record(identifier: notification.request.identifier, userInfo: info)
    if let timerId = info["cancel_timer"] as? Int {
      AlarmIds.cancel(timerId: timerId)
      return [.list]
    }
    // A Byte message for the conversation already on screen doesn't need a banner over it.
    if (info["channel"] as? String) == "byte", AppModel.shared.isShowingBuddy {
      return [.list]
    }
    return [.banner, .list, .sound]
  }

  func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
    await NotificationResponder.handle(response)
  }
}

final class SceneDelegate: NSObject, UIWindowSceneDelegate {
  func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem, completionHandler: @escaping (Bool) -> Void) {
    Task {
      await QuickActions.perform(shortcutItem)
      completionHandler(true)
    }
  }
}

/// What happens when a notification, or one of its buttons, is pressed.
enum NotificationResponder {
  @MainActor
  static func handle(_ response: UNNotificationResponse) async {
    let content = response.notification.request.content
    let info = content.userInfo
    let actionId = response.actionIdentifier

    if actionId == UNNotificationDefaultActionIdentifier {
      if let raw = info["url"] as? String {
        AppModel.shared.open(urlString: raw)
      } else if (info["channel"] as? String) == "byte" {
        AppModel.shared.route = .buddy(conversationId: info["conversation_id"] as? Int)
      }
      return
    }
    if actionId == UNNotificationDismissActionIdentifier { return }

    if actionId == "reply", let text = (response as? UNTextInputNotificationResponse)?.userText {
      Outbox.enqueue(OutboxItem(kind: .buddy, text: text, data: .object(["conversation_id": JSONValue(info["conversation_id"])]), source: "notification"))
      await Outbox.flush()
      return
    }
    if actionId == "mark_read" {
      Outbox.enqueue(OutboxItem(kind: .trigger, key: "ios_notification_action", data: .object([
        "action": .string("mark_read"),
        "tag": JSONValue(info["tag"]),
        "conversation_id": JSONValue(info["conversation_id"]),
      ]), source: "notification"))
      await Outbox.flush()
      return
    }

    // A dynamic button: answer whatever the notification was asking.
    let specs = NotificationActions.parse(info["actions"]) ?? []
    let spec = specs.first { $0.id == actionId }
    let typed = (response as? UNTextInputNotificationResponse)?.userText
    var data: [String: JSONValue] = [
      "action": .string(actionId),
      "title": JSONValue(spec?.title),
      "value": JSONValue(typed ?? spec?.value ?? actionId),
      "tag": JSONValue(info["tag"]),
      "channel": JSONValue(info["channel"]),
    ]
    if let answer = info["answer"] as? [String: Any] {
      for (key, value) in answer { data[key] = JSONValue(value) }
    }
    if let buttonAction = (info["button_actions"] as? [String: Any])?[actionId],
       let json = try? JSONSerialization.data(withJSONObject: buttonAction),
       let action = try? SharedStore.decoder.decode(ButtonAction.self, from: json) {
      let outcome = await ActionRunner.run(action, typed: typed, source: "notification")
      if case .open(let url) = outcome { AppModel.shared.handle(url: url) }
      return
    }
    Outbox.enqueue(OutboxItem(kind: .answer, text: spec?.title ?? typed, data: .object(data), source: "notification"))
    await Outbox.flush()
    if spec?.foreground == true, let raw = info["url"] as? String {
      AppModel.shared.open(urlString: raw)
    }
  }
}
