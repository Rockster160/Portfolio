import ActivityKit
import AlarmKit
import AppIntents
import SwiftUI

/// Server timers on the phone: a Live Activity for each running one, and optionally an AlarmKit
/// alarm so it rings like the Clock app. The server is the source of truth; this reconciles to it
/// on every push and every foreground.
enum TimerSync {
  /// Starts listening for the push-to-start token so the server can start a Live Activity while
  /// the app is closed, and for each activity's own update token.
  static func observeTokens() {
    Task {
      for await token in Activity<TimerActivityAttributes>.pushToStartTokenUpdates {
        let hex = token.map { String(format: "%02x", $0) }.joined()
        var tokens = SharedStore.load([String: String].self, key: "push_to_start_tokens") ?? [:]
        tokens["timer"] = hex
        SharedStore.save(tokens, key: "push_to_start_tokens")
        await DeviceSync.push()
      }
    }
    Task {
      for await activity in Activity<TimerActivityAttributes>.activityUpdates {
        observe(activity)
      }
    }
    for activity in Activity<TimerActivityAttributes>.activities { observe(activity) }
  }

  private static func observe(_ activity: Activity<TimerActivityAttributes>) {
    Task {
      for await token in activity.pushTokenUpdates {
        let hex = token.map { String(format: "%02x", $0) }.joined()
        _ = try? await APIClient.shared.post("api/ios/live_activities", body: [
          "activity_id": activity.id,
          "kind": "timer",
          "ref_id": String(activity.attributes.timerId),
          "push_token": hex,
        ])
      }
    }
    Task {
      for await state in activity.activityStateUpdates where state == .ended || state == .dismissed {
        _ = try? await APIClient.shared.delete("api/ios/live_activities/\(activity.id)")
      }
    }
  }

  static func reconcile() async {
    guard Session.isSignedIn else { return }
    guard let timers = try? await APIClient.shared.get("api/ios/timers", as: [TimerData].self) else { return }
    for timer in timers { await apply(timer) }
    let live = Set(timers.filter { $0.state != "done" }.map(\.id))
    for activity in Activity<TimerActivityAttributes>.activities where !live.contains(activity.attributes.timerId) {
      await activity.end(nil, dismissalPolicy: .immediate)
    }
    await AlarmBridge.cancelMissing(keeping: live)
  }

  static func apply(_ timer: TimerData) async {
    let preferences = Preferences.current
    let isAlarm = timer.kind == "alarm"
    if Feature.liveActivities.isEnabled, isAlarm ? preferences.liveActivitiesForAlarms : preferences.liveActivitiesForTimers {
      await updateActivity(timer)
    }
    if Feature.alarms.isEnabled, timer.kind != "wait", isAlarm ? preferences.alarmsRingAlarms : preferences.alarmsRingTimers {
      await AlarmBridge.sync(timer)
    }
  }

  private static func updateActivity(_ timer: TimerData) async {
    let state = TimerActivityAttributes.ContentState(timer: timer)
    let existing = Activity<TimerActivityAttributes>.activities.first { $0.attributes.timerId == timer.id }
    if timer.state == "done" {
      await existing?.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .immediate)
      return
    }
    let stale = timer.endsAt.map { $0.addingTimeInterval(timer.state == "fired" ? 3600 : 60) }
    if let existing {
      let alert = timer.state == "fired" && existing.content.state.state != "fired"
        ? AlertConfiguration(title: "\(timer.name)", body: "Time's up", sound: timer.alertSound)
        : nil
      await existing.update(ActivityContent(state: state, staleDate: stale), alertConfiguration: alert)
      return
    }
    guard ActivityAuthorizationInfo().areActivitiesEnabled, timer.state != "fired" else { return }
    let attributes = TimerActivityAttributes(timerId: timer.id, name: timer.name, icon: timer.icon, color: timer.color, kind: timer.kind)
    _ = try? Activity.request(attributes: attributes, content: ActivityContent(state: state, staleDate: stale), pushType: .token)
  }
}

/// AlarmKit, so a timer can ring through silent mode and Focus with a full-screen alert.
enum AlarmBridge {
  struct Metadata: AlarmMetadata {
    var timerId: Int
  }

  private static let mapKey = "alarm_ids"

  /// Server timer id → the AlarmKit id scheduled for it.
  private static var ids: [String: String] {
    get { SharedStore.load([String: String].self, key: mapKey) ?? [:] }
    set { SharedStore.save(newValue, key: mapKey) }
  }

  static func requestAuthorization() async -> Bool {
    let state = (try? await AlarmManager.shared.requestAuthorization()) ?? .denied
    return state == .authorized
  }

  static var authorizationState: PermissionState {
    switch AlarmManager.shared.authorizationState {
    case .authorized: return .granted
    case .denied: return .denied
    default: return .undetermined
    }
  }

  static func sync(_ timer: TimerData) async {
    let key = String(timer.id)
    let existing = ids[key].flatMap(UUID.init(uuidString:))
    switch timer.state {
    case "running":
      guard let end = timer.endsAt, end > Date() else { return }
      if let existing { try? AlarmManager.shared.cancel(id: existing) }
      let id = UUID()
      let tint = Color(css: timer.color) ?? .orange
      let alert = AlarmPresentation.Alert(
        title: LocalizedStringResource(stringLiteral: timer.name),
        stopButton: AlarmButton(text: "Stop", textColor: .white, systemImageName: "stop.fill"),
        secondaryButton: AlarmButton(text: "Snooze", textColor: .white, systemImageName: "zzz"),
        secondaryButtonBehavior: .countdown,
      )
      let countdown = AlarmPresentation.Countdown(
        title: LocalizedStringResource(stringLiteral: timer.name),
        pauseButton: AlarmButton(text: "Pause", textColor: .white, systemImageName: "pause.fill"),
      )
      let paused = AlarmPresentation.Paused(
        title: "Paused",
        resumeButton: AlarmButton(text: "Resume", textColor: .white, systemImageName: "play.fill"),
      )
      let attributes = AlarmAttributes<Metadata>(
        presentation: AlarmPresentation(alert: alert, countdown: countdown, paused: paused),
        metadata: Metadata(timerId: timer.id),
        tintColor: tint,
      )
      let configuration = AlarmManager.AlarmConfiguration<Metadata>(
        countdownDuration: Alarm.CountdownDuration(preAlert: end.timeIntervalSinceNow, postAlert: 9 * 60),
        attributes: attributes,
        stopIntent: AlarmStopIntent(timerId: timer.id),
        sound: timer.alertSound,
      )
      do {
        _ = try await AlarmManager.shared.schedule(id: id, configuration: configuration)
        ids[key] = id.uuidString
      } catch {
        ActivityLog.add("Couldn't schedule alarm for \(timer.name): \(error.localizedDescription)")
      }
    case "paused":
      if let existing { try? AlarmManager.shared.pause(id: existing) }
    default:
      if let existing {
        try? AlarmManager.shared.cancel(id: existing)
        ids[key] = nil
      }
    }
  }

  static func cancelMissing(keeping live: Set<Int>) async {
    for (key, raw) in ids where !live.contains(Int(key) ?? -1) {
      if let id = UUID(uuidString: raw) { try? AlarmManager.shared.cancel(id: id) }
      ids[key] = nil
    }
  }
}

/// Stopping a ringing alarm also confirms the timer on the server, so every other screen stops too.
struct AlarmStopIntent: LiveActivityIntent {
  static let title: LocalizedStringResource = "Stop Timer"
  static let isDiscoverable = false

  @Parameter(title: "Timer") var timerId: Int

  init() {}
  init(timerId: Int) { self.timerId = timerId }

  func perform() async throws -> some IntentResult {
    _ = try? await APIClient.shared.post("api/ios/timers/\(timerId)/confirm", body: [String: String]())
    return .result()
  }
}
