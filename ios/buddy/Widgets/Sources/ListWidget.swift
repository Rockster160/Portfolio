import AppIntents
import SwiftUI
import WidgetKit

struct ListWidgetIntent: WidgetConfigurationIntent {
  static let title: LocalizedStringResource = "List"
  static let description = IntentDescription("Shows a list's items. Tap an item to check it off.")

  @Parameter(title: "List") var list: ListEntity?
  @Parameter(title: "Show buttons", default: true) var showButtons: Bool
  @Parameter(title: "Buttons (Jil tasks)") var buttonTasks: [TaskEntity]?
  @Parameter(title: "Tap checks items off", default: true) var tapToCheck: Bool
  @Parameter(title: "Important first", default: true) var importantFirst: Bool
}

struct ListEntry: TimelineEntry {
  var date: Date
  var data: ListWidgetData?
  var stale: Bool
  var configuration: ListWidgetIntent
  var signedIn: Bool
}

struct ListProvider: AppIntentTimelineProvider {
  func placeholder(in context: Context) -> ListEntry {
    ListEntry(date: Date(), data: .sample, stale: false, configuration: ListWidgetIntent(), signedIn: true)
  }

  func snapshot(for configuration: ListWidgetIntent, in context: Context) async -> ListEntry {
    if context.isPreview { return placeholder(in: context) }
    return await entry(configuration)
  }

  func timeline(for configuration: ListWidgetIntent, in context: Context) async -> Timeline<ListEntry> {
    Timeline(entries: [await entry(configuration)], policy: .after(WidgetFetch.nextRefresh()))
  }

  private func entry(_ configuration: ListWidgetIntent) async -> ListEntry {
    guard Session.isSignedIn else {
      return ListEntry(date: Date(), data: nil, stale: false, configuration: configuration, signedIn: false)
    }
    let id = configuration.list?.id ?? Catalog.cached.lists.first?.id ?? ""
    let tasks = (configuration.buttonTasks ?? []).map(\.id).joined(separator: ",")
    var (data, stale) = await WidgetFetch.load(
      "api/ios/widgets/list/\(id)",
      query: ["tasks": tasks.isEmpty ? nil : tasks],
      cacheKey: "list-\(id)-\(tasks)",
      as: ListWidgetData.self,
    )
    if let loaded = data {
      data = WidgetOverrides.apply(to: loaded)
      await ImageCache.prefetch((loaded.buttons ?? []).map(\.style?.image))
    }
    return ListEntry(date: Date(), data: data, stale: stale, configuration: configuration, signedIn: true)
  }
}

struct ListWidgetView: View {
  var entry: ListEntry
  @Environment(\.widgetFamily) private var family
  @Environment(\.colorScheme) private var scheme

  private var theme: WidgetTheme { WidgetTheme.current(scheme) }

  var body: some View {
    Group {
      if !entry.signedIn {
        SignedOutView()
      } else if let data = entry.data {
        content(data)
      } else {
        WidgetNote(text: "Pick a list")
      }
    }
    .widgetBackground(.page)
    .widgetURL(entry.data.map { DeepLink.web($0.url ?? "/lists/\($0.id)") })
  }

  /// Rows a column holds, the header and a row of buttons taken out.
  private var capacity: Int {
    let buttons = showsButtons ? 2 : 0
    switch family {
    case .systemSmall: return 7
    case .systemMedium: return 7 - buttons
    case .systemLarge, .systemExtraLarge: return 19 - buttons
    case .accessoryRectangular: return 3
    default: return 4
    }
  }

  private var showsButtons: Bool {
    family != .systemSmall && entry.configuration.showButtons && !(entry.data?.buttons ?? []).isEmpty
  }

  @ViewBuilder
  private func content(_ data: ListWidgetData) -> some View {
    let open = items(data)
    if family == .accessoryRectangular {
      VStack(alignment: .leading, spacing: 1) {
        Text(data.name).font(SiteFont.arial(15, bold: true)).widgetAccentable()
        ForEach(open.prefix(capacity)) { Text("• \($0.name)").font(SiteFont.arial(12)).lineLimit(1) }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    } else if family == .accessoryCircular {
      VStack(spacing: 0) {
        Text("\(open.count)").font(SiteFont.arial(22, bold: true))
        Text(data.name).font(SiteFont.arial(9)).lineLimit(1)
      }
    } else if family == .accessoryInline {
      Text("\(data.name): \(open.count)")
    } else {
      VStack(alignment: .leading, spacing: 3) {
        WidgetHeader(title: data.name, icon: "ti-fa-list_ul", stale: entry.stale, trailing: "\(open.count)")
        if showsButtons, let buttons = data.buttons {
          HStack(spacing: 8) {
            ForEach(buttons.prefix(family == .systemMedium ? 8 : 12)) { button in
              ActionButton(action: button.action, source: "widget_list") {
                WidgetCircleButton(label: button.name, style: button.style, on: button.on, size: 26, showsLabel: false)
              }
            }
          }
          .padding(.vertical, 2)
        }
        if open.isEmpty {
          Spacer()
          Text("All done").font(SiteFont.arial(13, bold: true)).foregroundStyle(theme.muted).frame(maxWidth: .infinity)
          Spacer()
        } else {
          let columns = family == .systemMedium || family == .systemExtraLarge ? 2 : 1
          let shown = Array(open.prefix(capacity * columns))
          LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .leading), count: columns),
            alignment: .leading,
            spacing: 2,
          ) {
            ForEach(shown) { item in row(item, list: data) }
          }
          Spacer(minLength: 0)
          if open.count > shown.count {
            Text("+\(open.count - shown.count) more").font(SiteFont.arial(10)).foregroundStyle(theme.muted)
          }
        }
      }
    }
  }

  private func items(_ data: ListWidgetData) -> [ListWidgetData.Item] {
    let open = data.items.filter { $0.checked != true }
    guard entry.configuration.importantFirst else { return open }
    return open.filter { $0.important == true } + open.filter { $0.important != true }
  }

  /// One line, as the list reads on a Lock Screen: a box to tick, the item's icon and its name, an
  /// important item's box in gold.
  @ViewBuilder
  private func row(_ item: ListWidgetData.Item, list: ListWidgetData) -> some View {
    let mark = item.important == true ? WidgetTheme.important : theme.site.text.opacity(0.5)
    let label = HStack(spacing: 5) {
      RoundedRectangle(cornerRadius: 2.5)
        .strokeBorder(mark, lineWidth: 1.5)
        .frame(width: 10, height: 10)
      if let icon = item.icon { BuddyIcon(name: icon, size: 11, color: theme.site.text) }
      Text(item.name)
        .font(SiteFont.arial(13))
        .lineLimit(1)
        .foregroundStyle(Color(css: item.color) ?? theme.site.text)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
    if entry.configuration.tapToCheck {
      Button(intent: ToggleListItemIntent(listId: list.id, itemId: item.id, name: item.name, checked: item.checked != true)) { label }
        .buttonStyle(.plain)
    } else {
      label
    }
  }
}

struct ListWidget: Widget {
  var body: some WidgetConfiguration {
    AppIntentConfiguration(kind: "BuddyList", intent: ListWidgetIntent.self, provider: ListProvider()) { entry in
      ListWidgetView(entry: entry)
    }
    .configurationDisplayName("List")
    .description("A list, checkable in place, with its buttons.")
    .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge, .accessoryRectangular, .accessoryCircular, .accessoryInline])
    .pushHandler(BuddyWidgetPushHandler.self)
  }
}

extension ListWidgetData {
  static let sample = ListWidgetData(
    id: 0,
    name: "Groceries",
    url: nil,
    count: 4,
    items: [
      Item(id: 1, name: "Milk", important: true),
      Item(id: 2, name: "Eggs"),
      Item(id: 3, name: "Coffee"),
      Item(id: 4, name: "Bananas"),
    ],
    buttons: nil,
  )
}
