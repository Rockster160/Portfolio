import ActivityKit
import AppIntents
import Foundation

/// Buttons on a timer's Live Activity. LiveActivityIntent runs in the app's process, so the
/// server call and the activity update happen together even with the app closed.
struct TimerControlIntent: LiveActivityIntent {
  static let title: LocalizedStringResource = "Control Timer"
  static let isDiscoverable = false

  enum Command: String, AppEnum {
    case pause
    case resume
    case cancel
    case confirm

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Timer Command"
    static let caseDisplayRepresentations: [Command: DisplayRepresentation] = [
      .pause: "Pause",
      .resume: "Resume",
      .cancel: "Cancel",
      .confirm: "Done",
    ]
  }

  @Parameter(title: "Timer") var timerId: Int
  @Parameter(title: "Command") var command: Command

  init() {}

  init(timerId: Int, command: Command) {
    self.timerId = timerId
    self.command = command
  }

  func perform() async throws -> some IntentResult {
    let reply = try? await APIClient.shared.post(
      "api/ios/timers/\(timerId)/\(command.rawValue)",
      body: [String: String](),
      as: TimerData.self,
    )
    for activity in Activity<TimerActivityAttributes>.activities where activity.attributes.timerId == timerId {
      if command == .cancel || command == .confirm {
        await activity.end(nil, dismissalPolicy: .immediate)
      } else if let reply {
        await activity.update(ActivityContent(state: .init(timer: reply), staleDate: nil))
      } else {
        // Offline: show the change locally; the server push will correct it later.
        var state = activity.content.state
        if command == .pause, let end = state.endDate {
          state.pausedRemaining = max(0, end.timeIntervalSinceNow)
          state.state = "paused"
        } else if command == .resume, let remaining = state.pausedRemaining {
          state.endsAt = Date().addingTimeInterval(remaining).timeIntervalSince1970
          state.state = "running"
        }
        await activity.update(ActivityContent(state: state, staleDate: nil))
      }
    }
    return .result()
  }
}
