import AppIntents
import SwiftUI
import WidgetKit

/// A grid of Jil task buttons, the same as the big buttons on lists and boards: a press runs the
/// task, and each button wears its task's last monitor frame (icon, text, color), so its state
/// shows the way a HASS entity button's does.
struct ButtonsWidgetIntent: WidgetConfigurationIntent {
  static let title: LocalizedStringResource = "Task Buttons"
  static let description = IntentDescription("Jil task buttons that show their task's state and run it when pressed.")

  @Parameter(title: "Tasks") var tasks: [TaskEntity]?
  @Parameter(title: "Title") var title: String?
}

struct ButtonsEntry: TimelineEntry {
  struct Item: Identifiable {
    var id: String
    var label: String?
    var style: Styled?
    var on: Bool?
    var action: ButtonAction?
  }

  var date: Date
  var title: String?
  var items: [Item]
  var stale: Bool
  var signedIn: Bool
  var showTitle: Bool
}

struct ButtonsProvider: AppIntentTimelineProvider {
  func placeholder(in context: Context) -> ButtonsEntry {
    ButtonsEntry(
      date: Date(),
      title: "Home",
      items: [
        .init(id: "1", label: "Garage", style: Styled(icon: "sf:door.garage.closed", background: "#34c759"), on: true),
        .init(id: "2", label: "Lights", style: Styled(icon: "sf:lightbulb.fill", background: "#ffcc00"), on: true),
        .init(id: "3", label: "Lock", style: Styled(icon: "sf:lock.fill", background: "#0150d5")),
        .init(id: "4", label: "Car", style: Styled(icon: "sf:car.fill", background: "#ff3b30")),
      ],
      stale: false,
      signedIn: true,
      showTitle: true,
    )
  }

  func snapshot(for configuration: ButtonsWidgetIntent, in context: Context) async -> ButtonsEntry {
    if context.isPreview { return placeholder(in: context) }
    return await entry(configuration)
  }

  func timeline(for configuration: ButtonsWidgetIntent, in context: Context) async -> Timeline<ButtonsEntry> {
    Timeline(entries: [await entry(configuration)], policy: .after(WidgetFetch.nextRefresh()))
  }

  private func entry(_ configuration: ButtonsWidgetIntent) async -> ButtonsEntry {
    let signedIn = Session.isSignedIn
    var entry = ButtonsEntry(date: Date(), title: nil, items: [], stale: false, signedIn: signedIn, showTitle: configuration.title != nil)
    guard signedIn else { return entry }
    let ids = (configuration.tasks ?? []).map(\.id).joined(separator: ",")
    let (data, stale) = await WidgetFetch.load(
      "api/ios/widgets/buttons",
      query: ["tasks": ids],
      cacheKey: "buttons-\(ids)",
      as: TaskButtonsData.self,
    )
    entry.title = configuration.title
    entry.stale = stale
    entry.items = (data?.buttons ?? []).map { .init(id: $0.id, label: $0.name, style: $0.style, on: $0.on, action: $0.action) }
    await ImageCache.prefetch(entry.items.map(\.style?.image))
    return entry
  }
}

struct ButtonsWidgetView: View {
  var entry: ButtonsEntry
  @Environment(\.widgetFamily) private var family

  private var capacity: Int {
    switch family {
    case .systemSmall: return 4
    case .systemMedium: return 8
    case .systemLarge: return 16
    case .systemExtraLarge: return 24
    case .accessoryRectangular: return 3
    default: return 1
    }
  }

  private var columns: Int {
    switch family {
    case .systemSmall: return 2
    case .systemMedium: return 4
    case .systemExtraLarge: return 6
    case .accessoryRectangular: return 3
    default: return 4
    }
  }

  var body: some View {
    Group {
      if !entry.signedIn {
        SignedOutView()
      } else if entry.items.isEmpty {
        WidgetNote(text: "Pick tasks in Edit Widget")
      } else if family == .accessoryCircular, let first = entry.items.first {
        ActionButton(action: first.action, source: "widget_buttons") {
          ZStack {
            AccessoryWidgetBackground()
            BuddyIcon(name: first.style?.icon, fallbackText: first.label, size: 22)
          }
        }
      } else {
        VStack(spacing: 6) {
          if entry.showTitle, let title = entry.title, family != .accessoryRectangular {
            WidgetHeader(title: title, icon: "ti-fa-th_large", stale: entry.stale)
          }
          let shown = Array(entry.items.prefix(capacity))
          let rows = stride(from: 0, to: shown.count, by: columns).map { Array(shown[$0..<min($0 + columns, shown.count)]) }
          ForEach(rows.indices, id: \.self) { index in
            HStack(spacing: 6) {
              ForEach(rows[index]) { item in
                ActionButton(action: item.action, source: "widget_buttons") {
                  WidgetButtonFace(label: item.label, style: item.style, on: item.on, compact: family != .systemLarge)
                }
              }
            }
          }
        }
      }
    }
    .widgetBackground()
  }
}

struct ButtonsWidget: Widget {
  var body: some WidgetConfiguration {
    AppIntentConfiguration(kind: "BuddyButtons", intent: ButtonsWidgetIntent.self, provider: ButtonsProvider()) { entry in
      ButtonsWidgetView(entry: entry)
    }
    .configurationDisplayName("Task Buttons")
    .description("Jil task buttons; each shows its task's state and runs it when pressed.")
    .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge, .accessoryCircular, .accessoryRectangular])
    .pushHandler(BuddyWidgetPushHandler.self)
  }
}
