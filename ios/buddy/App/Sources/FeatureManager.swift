import ActivityKit
import BackgroundTasks
import Contacts
import CoreBluetooth
import CoreLocation
import EventKit
import UIKit
import UserNotifications
import WidgetKit

/// Features are switched on the site; this starts and stops whatever the server's latest settings
/// changed, and does the one thing only the phone can: ask iOS for a permission.
@MainActor
final class FeatureManager {
  static let shared = FeatureManager()

  private(set) var enabled: Set<Feature> = Feature.enabled

  func isOn(_ feature: Feature) -> Bool { enabled.contains(feature) }

  /// The server's settings, as just fetched. Options can change while a feature stays on, so the
  /// ones that read them are restarted too.
  func apply(features: Set<Feature>, preferences: Preferences, hotLinks: [HotLink]) {
    let before = enabled
    enabled = features
    Feature.enabled = features
    Preferences.current = preferences
    HotLink.all = hotLinks
    for feature in features.subtracting(before) { start(feature) }
    for feature in before.subtracting(features) { stop(feature) }
    if features.contains(.location), before.contains(.location) { LocationService.shared.start() }
    QuickActions.refresh()
    WidgetCenter.shared.reloadAllTimelines()
  }

  /// Asked from a page in the app ("Allow on this iPhone"). Allowed, the server switches the
  /// feature on, and its settings come back with it.
  func requestPermission(_ feature: Feature) async -> PermissionState {
    _ = await permit(feature)
    let state = await Permissions.state(feature)
    await DeviceSync.push(turnOn: state == .granted ? [feature] : [])
    return state
  }

  /// One of the phone's own tasks, from a page in the app or a push from the site.
  func run(task: String) async {
    switch task {
    case "send_battery": BatteryMonitor.shared.report(force: true)
    case "check_workouts": await HealthService.shared.sendNewWorkouts()
    case "sync_calendar": await NativeSync.shared.syncCalendar()
    case "resend_calendar":
      NativeSync.shared.reset("calendar")
      await NativeSync.shared.syncCalendar()
    case "sync_reminders": await NativeSync.shared.syncReminders()
    case "sync_contacts": await NativeSync.shared.syncContacts()
    case "resend_contacts":
      NativeSync.shared.reset("contacts")
      await NativeSync.shared.syncContacts()
    case "refresh_widgets": WidgetCenter.shared.reloadAllTimelines()
    default: ActivityLog.add("Unknown device task: \(task)")
    }
  }

  private func permit(_ feature: Feature) async -> Bool {
    switch feature {
    case .push, .actionableNotifications:
      return await PushService.shared.enable()
    case .liveActivities:
      return ActivityAuthorizationInfo().areActivitiesEnabled
    case .alarms:
      return await AlarmBridge.requestAuthorization()
    case .location:
      let status = await LocationService.shared.requestAlways()
      return status == .authorizedAlways || status == .authorizedWhenInUse
    case .health:
      return await HealthService.shared.requestAuthorization()
    case .calendar:
      return await NativeSync.shared.requestCalendar()
    case .reminders:
      return await NativeSync.shared.requestReminders()
    case .contacts:
      return await NativeSync.shared.requestContacts()
    case .bluetoothBattery:
      return await BatteryMonitor.shared.requestBluetooth()
    case .battery, .hotLinks, .widgets, .quickCommands, .share:
      return true
    }
  }

  private func start(_ feature: Feature) {
    switch feature {
    case .push, .actionableNotifications:
      PushService.shared.register()
    case .liveActivities, .alarms:
      Task { await TimerSync.reconcile() }
    case .hotLinks:
      QuickActions.refresh()
    case .battery:
      BatteryMonitor.shared.start()
    case .bluetoothBattery:
      BatteryMonitor.shared.startAccessories()
    case .location:
      LocationService.shared.start()
    case .health:
      HealthService.shared.start()
      Task { await HealthService.shared.sendNewWorkouts() }
    case .calendar, .reminders, .contacts:
      NativeSync.shared.startObserving()
      Task { await syncAll(reason: "enabled") }
    case .widgets, .quickCommands, .share:
      break
    }
    BackgroundWork.schedule()
  }

  private func stop(_ feature: Feature) {
    switch feature {
    case .push:
      UIApplication.shared.unregisterForRemoteNotifications()
    case .liveActivities:
      Task {
        for activity in Activity<TimerActivityAttributes>.activities { await activity.end(nil, dismissalPolicy: .immediate) }
      }
    case .alarms:
      Task { await AlarmBridge.cancelMissing(keeping: []) }
    case .hotLinks:
      UIApplication.shared.shortcutItems = []
    case .battery:
      BatteryMonitor.shared.stop()
    case .bluetoothBattery:
      BatteryMonitor.shared.stopAccessories()
    case .location:
      LocationService.shared.stop()
    case .health:
      HealthService.shared.stop()
    case .calendar:
      NativeSync.shared.reset("calendar")
    case .reminders:
      NativeSync.shared.reset("reminders")
    case .contacts:
      NativeSync.shared.reset("contacts")
    case .actionableNotifications, .widgets, .quickCommands, .share:
      break
    }
  }

  /// Everything that was on last time starts again at launch — including a relaunch by iOS for a
  /// location event or a background upload, when there's no UI at all.
  nonisolated func resumeEnabledFeatures(launchOptions: [UIApplication.LaunchOptionsKey: Any]?) {
    Task { @MainActor in
      TimerSync.observeTokens()
      for feature in enabled { start(feature) }
      await Outbox.flush()
    }
  }

  /// One pass that brings everything up to date, used on foreground, background refresh and a
  /// server "sync" push alike.
  func syncAll(reason: String) async {
    guard Session.isSignedIn else { return }
    await Outbox.flush()
    if isOn(.battery) { BatteryMonitor.shared.report(force: reason == "refresh") }
    if isOn(.health) {
      await HealthService.shared.sendNewWorkouts()
      await HealthService.shared.sendDailyTotals()
    }
    if isOn(.calendar) { await NativeSync.shared.syncCalendar() }
    if isOn(.reminders) { await NativeSync.shared.syncReminders() }
    if isOn(.contacts) { await NativeSync.shared.syncContacts() }
    if isOn(.liveActivities) || isOn(.alarms) { await TimerSync.reconcile() }
    if isOn(.location) { LocationService.shared.refreshRegions() }
    await Outbox.flush()
  }
}

enum PermissionState: String {
  case granted
  case denied
  case undetermined
}

/// What iOS currently allows, read without asking, so the site can show which features are
/// waiting on a tap and which iOS has refused.
@MainActor
enum Permissions {
  static func state(_ feature: Feature) async -> PermissionState {
    switch feature {
    case .push:
      switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
      case .authorized, .provisional, .ephemeral: return .granted
      case .denied: return .denied
      default: return .undetermined
      }
    case .alarms:
      return AlarmBridge.authorizationState
    case .location:
      switch LocationService.shared.manager.authorizationStatus {
      case .authorizedAlways, .authorizedWhenInUse: return .granted
      case .denied, .restricted: return .denied
      default: return .undetermined
      }
    case .health:
      return await HealthService.shared.authorizationState()
    case .calendar:
      return events(EKEventStore.authorizationStatus(for: .event))
    case .reminders:
      return events(EKEventStore.authorizationStatus(for: .reminder))
    case .contacts:
      switch CNContactStore.authorizationStatus(for: .contacts) {
      case .authorized, .limited: return .granted
      case .denied, .restricted: return .denied
      default: return .undetermined
      }
    case .bluetoothBattery:
      switch CBCentralManager.authorization {
      case .allowedAlways: return .granted
      case .denied, .restricted: return .denied
      default: return .undetermined
      }
    case .actionableNotifications, .liveActivities, .hotLinks, .widgets, .quickCommands, .battery, .share:
      return .granted
    }
  }

  static func all() async -> [String: String] {
    var states: [String: String] = [:]
    for feature in Feature.allCases where feature.requiresPermission {
      states[feature.rawValue] = await state(feature).rawValue
    }
    return states
  }

  private static func events(_ status: EKAuthorizationStatus) -> PermissionState {
    switch status {
    case .fullAccess: return .granted
    case .denied, .restricted, .writeOnly: return .denied
    default: return .undetermined
    }
  }
}

/// Background refresh: the system wakes the app now and then to send anything queued and catch up
/// the syncs. A backstop behind the pushes and change notifications, never the main mechanism.
enum BackgroundWork {
  static let refreshId = "com.ardesian.buddy.refresh"
  static let flushId = "com.ardesian.buddy.flush"

  static func register() {
    BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshId, using: nil) { task in
      schedule()
      let work = Task { @MainActor in
        await FeatureManager.shared.syncAll(reason: "refresh")
        task.setTaskCompleted(success: true)
      }
      task.expirationHandler = { work.cancel() }
    }
    BGTaskScheduler.shared.register(forTaskWithIdentifier: flushId, using: nil) { task in
      let work = Task {
        await Outbox.flush()
        task.setTaskCompleted(success: Outbox.pendingCount == 0)
      }
      task.expirationHandler = { work.cancel() }
    }
  }

  static func schedule() {
    let refresh = BGAppRefreshTaskRequest(identifier: refreshId)
    refresh.earliestBeginDate = Date().addingTimeInterval(30 * 60)
    try? BGTaskScheduler.shared.submit(refresh)
    if Outbox.pendingCount > 0 {
      let flush = BGProcessingTaskRequest(identifier: flushId)
      flush.requiresNetworkConnectivity = true
      try? BGTaskScheduler.shared.submit(flush)
    }
  }
}

/// Home Screen quick actions, built from the hot links.
enum QuickActions {
  static var pending: UIApplicationShortcutItem?

  @MainActor
  static func refresh() {
    guard Feature.hotLinks.isEnabled else {
      UIApplication.shared.shortcutItems = []
      return
    }
    UIApplication.shared.shortcutItems = HotLink.all.map { link in
      UIApplicationShortcutItem(
        type: "hot-link",
        localizedTitle: link.title,
        localizedSubtitle: link.subtitle,
        icon: UIApplicationShortcutIcon(systemImageName: link.icon),
        userInfo: ["id": link.id as NSString],
      )
    }
  }

  @MainActor
  static func perform(_ item: UIApplicationShortcutItem) async {
    guard let id = item.userInfo?["id"] as? String, let link = HotLink.all.first(where: { $0.id == id }) else { return }
    await AppModel.shared.run(link.action, source: "hot_link")
  }

  @MainActor
  static func performPending() async {
    guard let item = pending else { return }
    pending = nil
    await perform(item)
  }
}
