import AlarmKit
import Foundation

/// Server timer id → the AlarmKit alarm scheduled for it. Kept in the App Group, so the
/// notification extension can cancel an alarm while the app isn't running.
enum AlarmIds {
  private static let key = "alarm_ids"

  static var all: [String: String] {
    get { SharedStore.load([String: String].self, key: key) ?? [:] }
    set { SharedStore.save(newValue, key: key) }
  }

  /// Cancels the timer's alarm, if this phone has one.
  static func cancel(timerId: Int) {
    let key = String(timerId)
    guard let raw = all[key] else { return }
    if let id = UUID(uuidString: raw) { try? AlarmManager.shared.cancel(id: id) }
    all[key] = nil
  }
}
