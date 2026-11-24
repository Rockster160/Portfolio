import ActivityKit
import Foundation

/// A server timer or alarm on the Lock Screen. The type name and every key are part of the push
/// contract: the server starts these with push-to-start using `attributes-type` =
/// "TimerActivityAttributes", so renaming anything here silently breaks remote starts.
struct TimerActivityAttributes: ActivityAttributes {
  struct ContentState: Codable, Hashable {
    var name: String
    /// Epoch seconds. Plain numbers rather than Date, because ActivityKit decodes pushed state
    /// with a default JSONDecoder whose Date format is seconds since 2001.
    var endsAt: Double?
    var startedAt: Double?
    /// Seconds left when paused.
    var pausedRemaining: Double?
    /// running | paused | fired | done
    var state: String

    enum CodingKeys: String, CodingKey {
      case name
      case endsAt = "ends_at"
      case startedAt = "started_at"
      case pausedRemaining = "paused_remaining"
      case state
    }

    var endDate: Date? { endsAt.map { Date(timeIntervalSince1970: $0) } }
    var startDate: Date? { startedAt.map { Date(timeIntervalSince1970: $0) } }
    var isPaused: Bool { state == "paused" }
    var isFired: Bool { state == "fired" }

    /// Which activity iOS puts in the Dynamic Island and first on the Lock Screen, highest first:
    /// one ringing, then the running one that ends soonest, then the paused ones. The server sends
    /// the same with each push (AppPush::Timers.relevance).
    var relevance: Double {
      if isFired { return 20_000_000_000 }
      guard !isPaused, let endsAt else { return 1 }
      return 10_000_000_000 - endsAt
    }

    /// The span a countdown text or progress bar should run over.
    var interval: ClosedRange<Date>? {
      guard let end = endDate else { return nil }
      let start = startDate ?? Date()
      return start <= end ? start...end : end...end
    }
  }

  var timerId: Int
  var name: String
  var icon: String?
  var color: String?
  /// timer | alarm | wait
  var kind: String?

  enum CodingKeys: String, CodingKey {
    case timerId = "timer_id"
    case name
    case icon
    case color
    case kind
  }
}

extension TimerActivityAttributes.ContentState {
  init(timer: TimerData) {
    self.init(
      name: timer.name,
      endsAt: timer.endsAt?.timeIntervalSince1970,
      startedAt: timer.startedAt?.timeIntervalSince1970,
      pausedRemaining: timer.pausedRemaining,
      state: timer.state,
    )
  }
}
