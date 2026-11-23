import AppIntents
import Foundation
import WidgetKit

/// What a widget button does when pressed. The action travels as JSON because a widget button can
/// carry any ButtonAction the server or the user configured.
struct RunActionIntent: AppIntent {
  static let title: LocalizedStringResource = "Run Buddy Action"
  static let isDiscoverable = false

  @Parameter(title: "Action") var payload: String
  @Parameter(title: "Source") var source: String

  init() {}

  init(_ action: ButtonAction, source: String) {
    let data = (try? SharedStore.encoder.encode(action)) ?? Data()
    payload = String(data: data, encoding: .utf8) ?? "{}"
    self.source = source
  }

  func perform() async throws -> some IntentResult {
    guard let data = payload.data(using: .utf8),
          let action = try? SharedStore.decoder.decode(ButtonAction.self, from: data) else {
      return .result()
    }
    await ActionRunner.run(action, source: source)
    // A press usually changes what the widget shows (a toggle, a state); ask for fresh data now.
    try? await Task.sleep(nanoseconds: 1_200_000_000)
    WidgetCenter.shared.reloadAllTimelines()
    return .result()
  }
}

/// Checks a list item off from the widget without opening anything.
struct ToggleListItemIntent: AppIntent {
  static let title: LocalizedStringResource = "Toggle List Item"
  static let isDiscoverable = false

  @Parameter(title: "List") var listId: String
  @Parameter(title: "Item") var itemId: Int
  @Parameter(title: "Name") var name: String
  @Parameter(title: "Checked") var checked: Bool

  init() {}

  init(listId: Int, itemId: Int, name: String, checked: Bool) {
    self.listId = String(listId)
    self.itemId = itemId
    self.name = name
    self.checked = checked
  }

  func perform() async throws -> some IntentResult {
    WidgetOverrides.set(listId: listId, itemId: itemId, checked: checked)
    WidgetCenter.shared.reloadAllTimelines()
    Outbox.enqueue(OutboxItem(
      kind: .listToggle,
      text: name,
      key: listId,
      data: .object(["item_id": .number(Double(itemId)), "checked": .bool(checked)]),
      source: "widget",
    ))
    await Outbox.flush()
    WidgetCenter.shared.reloadAllTimelines()
    return .result()
  }
}

/// A tick shows immediately in the widget even while the request is still queued, then the
/// server's copy takes over once it agrees.
enum WidgetOverrides {
  private static let key = "widget_list_overrides"

  static func set(listId: String, itemId: Int, checked: Bool) {
    var all = SharedStore.load([String: Bool].self, key: key) ?? [:]
    all["\(listId):\(itemId)"] = checked
    SharedStore.save(all, key: key)
  }

  static func apply(to data: ListWidgetData) -> ListWidgetData {
    var all = SharedStore.load([String: Bool].self, key: key) ?? [:]
    var copy = data
    copy.items = data.items.map { item in
      var item = item
      let overrideKey = "\(data.id):\(item.id)"
      if let checked = all[overrideKey] {
        if (item.checked ?? false) == checked {
          all.removeValue(forKey: overrideKey)
        } else {
          item.checked = checked
        }
      }
      return item
    }
    SharedStore.save(all, key: key)
    return copy
  }
}
