import Foundation

/// Everything the app can do beyond showing the site. What each one is, its options and its Jil
/// triggers are described on the site (app/service/app_devices/features.rb), which is also where
/// they're switched on; the phone keeps the server's last word here.
enum Feature: String, CaseIterable, Codable, Identifiable {
  case push
  case actionableNotifications = "actionable_notifications"
  case liveActivities = "live_activities"
  case alarms
  case hotLinks = "hot_links"
  case widgets
  case quickCommands = "quick_commands"
  case battery
  case bluetoothBattery = "bluetooth_battery"
  case location
  case health
  case calendar
  case reminders
  case contacts
  case share

  var id: String { rawValue }

  /// Asks iOS for something before it can work, so it waits for a tap on the phone.
  var requiresPermission: Bool {
    switch self {
    case .push, .alarms, .bluetoothBattery, .location, .health, .calendar, .reminders, .contacts:
      return true
    case .actionableNotifications, .liveActivities, .hotLinks, .widgets, .quickCommands, .battery, .share:
      return false
    }
  }

  /// What's on, as the server last said. Before it has said anything, everything that needs no
  /// permission, the same as a newly signed-in device on the server.
  static var enabled: Set<Feature> {
    get {
      guard let saved = SharedStore.load([String].self, key: SharedStore.Key.features) else {
        return Set(allCases.filter { !$0.requiresPermission })
      }
      return Set(saved.compactMap(Feature.init(rawValue:)))
    }
    set { SharedStore.save(newValue.map(\.rawValue).sorted(), key: SharedStore.Key.features) }
  }

  var isEnabled: Bool { Feature.enabled.contains(self) }
}

/// Per-feature options, set on the site and kept here as the server last sent them. The defaults
/// match the server's (AppDevice::DEFAULT_PREFERENCES) for a phone that hasn't heard yet.
struct Preferences: Codable, Equatable {
  /// Stop sending this account's web pushes to the home-screen web app once native push is on.
  var nativePushReplacesWebPush = false
  /// Which server channels arrive as native notifications.
  var pushChannels: [String] = ["byte", "timers", "agenda", "chores", "whisper", "jarvis"]
  /// Show the server's unread count on the app icon.
  var pushBadges = true
  /// Open links from notifications in the app rather than Safari.
  var openLinksInApp = true

  var liveActivitiesForTimers = true
  var liveActivitiesForAlarms = true
  /// Live Activities started by the server even while the app is closed (push-to-start).
  var liveActivitiesPushToStart = true

  var alarmsRingTimers = false
  var alarmsRingAlarms = true

  /// Write the dashboard's battery cache, which the battery Shortcut used to feed.
  var batteryWritesDashboard = true

  /// Kept on a "when it matters" footing by default; continuous is a heavier drain.
  var locationMode: LocationMode = .significant
  var locationVisits = true
  var locationRegions = true
  /// Feed arrivals and departures into the existing travel funnel (`trytravel`).
  var locationFeedsTravel = true
  var locationMinimumMeters: Double = 150

  var healthLogsWorkoutEvent = true
  var healthDailyTotals = false

  var calendarDaysBack = 7
  var calendarDaysAhead = 60
  var calendarIdentifiers: [String] = []

  var reminderListIdentifiers: [String] = []
  var remindersIncludeCompleted = false

  var commandsShowConfirmations = true

  enum LocationMode: String, Codable, CaseIterable, Identifiable {
    case significant
    case balanced
    case continuous
    var id: String { rawValue }
    var title: String {
      switch self {
      case .significant: return "Significant moves only"
      case .balanced: return "Balanced (~100 m)"
      case .continuous: return "Continuous (best accuracy)"
      }
    }
  }

  static var current: Preferences {
    get { SharedStore.load(Preferences.self, key: SharedStore.Key.preferences) ?? Preferences() }
    set { SharedStore.save(newValue, key: SharedStore.Key.preferences) }
  }

  init() {}

  /// New options added in a later version decode to their default instead of failing the whole
  /// struct and resetting every choice already made.
  init(from decoder: Decoder) throws {
    let defaults = Preferences()
    let container = try decoder.container(keyedBy: CodingKeys.self)
    func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
      (try? container.decodeIfPresent(T.self, forKey: key)) ?? fallback
    }
    nativePushReplacesWebPush = value(.nativePushReplacesWebPush, defaults.nativePushReplacesWebPush)
    pushChannels = value(.pushChannels, defaults.pushChannels)
    pushBadges = value(.pushBadges, defaults.pushBadges)
    openLinksInApp = value(.openLinksInApp, defaults.openLinksInApp)
    liveActivitiesForTimers = value(.liveActivitiesForTimers, defaults.liveActivitiesForTimers)
    liveActivitiesForAlarms = value(.liveActivitiesForAlarms, defaults.liveActivitiesForAlarms)
    liveActivitiesPushToStart = value(.liveActivitiesPushToStart, defaults.liveActivitiesPushToStart)
    alarmsRingTimers = value(.alarmsRingTimers, defaults.alarmsRingTimers)
    alarmsRingAlarms = value(.alarmsRingAlarms, defaults.alarmsRingAlarms)
    batteryWritesDashboard = value(.batteryWritesDashboard, defaults.batteryWritesDashboard)
    locationMode = value(.locationMode, defaults.locationMode)
    locationVisits = value(.locationVisits, defaults.locationVisits)
    locationRegions = value(.locationRegions, defaults.locationRegions)
    locationFeedsTravel = value(.locationFeedsTravel, defaults.locationFeedsTravel)
    locationMinimumMeters = value(.locationMinimumMeters, defaults.locationMinimumMeters)
    healthLogsWorkoutEvent = value(.healthLogsWorkoutEvent, defaults.healthLogsWorkoutEvent)
    healthDailyTotals = value(.healthDailyTotals, defaults.healthDailyTotals)
    calendarDaysBack = value(.calendarDaysBack, defaults.calendarDaysBack)
    calendarDaysAhead = value(.calendarDaysAhead, defaults.calendarDaysAhead)
    calendarIdentifiers = value(.calendarIdentifiers, defaults.calendarIdentifiers)
    reminderListIdentifiers = value(.reminderListIdentifiers, defaults.reminderListIdentifiers)
    remindersIncludeCompleted = value(.remindersIncludeCompleted, defaults.remindersIncludeCompleted)
    commandsShowConfirmations = value(.commandsShowConfirmations, defaults.commandsShowConfirmations)
  }
}
