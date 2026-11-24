import AppIntents
import SwiftUI
import WidgetKit

/// The agenda page's search decides what shows: the same words the search box takes
/// (is:event, kind:task, name:standup, -location:home, ...), run on the server over saved items
/// and recurring ones alike.
struct AgendaWidgetIntent: WidgetConfigurationIntent {
  static let title: LocalizedStringResource = "Agenda"
  static let description = IntentDescription("Upcoming agenda items, filtered with the agenda page's search.")

  @Parameter(title: "Search (blank for everything)") var query: String?
  @Parameter(title: "Days ahead", default: 2, inclusiveRange: (1, 365)) var days: Int
  @Parameter(title: "Title") var title: String?
  @Parameter(title: "Show locations", default: true) var showLocations: Bool
}

struct AgendaEntry: TimelineEntry {
  var date: Date
  var data: AgendaWidgetData?
  var stale: Bool
  var configuration: AgendaWidgetIntent
  var signedIn: Bool
}

struct AgendaProvider: AppIntentTimelineProvider {
  func placeholder(in context: Context) -> AgendaEntry {
    AgendaEntry(date: Date(), data: .sample, stale: false, configuration: AgendaWidgetIntent(), signedIn: true)
  }

  func snapshot(for configuration: AgendaWidgetIntent, in context: Context) async -> AgendaEntry {
    if context.isPreview { return placeholder(in: context) }
    return await entry(configuration, at: Date())
  }

  /// One entry per item start, so the widget drops a finished event at the moment it ends instead
  /// of waiting for the next fetch.
  func timeline(for configuration: AgendaWidgetIntent, in context: Context) async -> Timeline<AgendaEntry> {
    let first = await entry(configuration, at: Date())
    var entries = [first]
    let ends = (first.data?.items ?? []).compactMap { $0.endsAt ?? $0.startsAt }.filter { $0 > Date() }.sorted().prefix(10)
    for end in ends {
      var later = first
      later.date = end
      entries.append(later)
    }
    return Timeline(entries: entries, policy: .after(WidgetFetch.nextRefresh(minutes: 30)))
  }

  private func entry(_ configuration: AgendaWidgetIntent, at date: Date) async -> AgendaEntry {
    guard Session.isSignedIn else {
      return AgendaEntry(date: date, data: nil, stale: false, configuration: configuration, signedIn: false)
    }
    let search = configuration.query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let (data, stale) = await WidgetFetch.load(
      "api/ios/widgets/agenda",
      query: ["days": String(configuration.days), "limit": "20", "q": search.isEmpty ? nil : search],
      cacheKey: "agenda-\(configuration.days)-\(search)",
      as: AgendaWidgetData.self,
    )
    return AgendaEntry(date: date, data: data, stale: stale, configuration: configuration, signedIn: true)
  }
}

struct AgendaWidgetView: View {
  var entry: AgendaEntry
  @Environment(\.widgetFamily) private var family
  @Environment(\.colorScheme) private var scheme

  private var theme: WidgetTheme { WidgetTheme.current(scheme) }

  var body: some View {
    Group {
      if !entry.signedIn {
        SignedOutView()
      } else {
        content
      }
    }
    .widgetBackground(.page)
    .widgetURL(DeepLink.web(entry.data?.url ?? "/agenda"))
  }

  private var items: [AgendaWidgetData.Item] {
    (entry.data?.items ?? []).filter { item in
      if item.allDay == true, let start = item.startsAt {
        let dayAfter = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: start))
        return (dayAfter ?? start) > entry.date
      }
      return (item.endsAt ?? item.startsAt ?? .distantFuture) > entry.date
    }
  }

  /// Lines the widget holds under its header, a day's label taking one like an item does.
  private var capacity: Int {
    switch family {
    case .systemSmall, .systemMedium: return 6
    case .systemLarge, .systemExtraLarge: return 16
    case .accessoryRectangular: return 2
    default: return 1
    }
  }

  @ViewBuilder
  private var content: some View {
    let title = entry.configuration.title ?? entry.data?.title ?? "Agenda"
    switch family {
    case .accessoryInline:
      if let next = items.first {
        Text("\(time(next)) \(next.title)")
      } else {
        Text("Nothing scheduled")
      }
    case .accessoryCircular:
      VStack(spacing: 0) {
        Text("\(items.count)").font(SiteFont.arial(22, bold: true))
        Text("next").font(SiteFont.arial(9))
      }
    case .accessoryRectangular:
      VStack(alignment: .leading, spacing: 1) {
        ForEach(items.prefix(capacity)) { item in
          Text(item.title).font(SiteFont.arial(15, bold: true)).lineLimit(1).widgetAccentable()
          Text(time(item)).font(SiteFont.arial(12)).opacity(0.7)
        }
        if items.isEmpty { Text("Nothing scheduled").font(SiteFont.arial(12)) }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    default:
      VStack(alignment: .leading, spacing: 2) {
        WidgetHeader(title: title, icon: "ti-fa-calendar", stale: entry.stale)
        if items.isEmpty {
          Text("Nothing scheduled")
            .font(SiteFont.arial(13))
            .foregroundStyle(theme.muted)
          Spacer(minLength: 0)
        } else {
          ForEach(fitted, id: \.0) { day, dayItems in
            if entry.configuration.days > 1 {
              Text(day)
                .font(SiteFont.arial(11, bold: true))
                .foregroundStyle(theme.muted)
                .padding(.top, 2)
            }
            ForEach(dayItems) { row($0) }
          }
          Spacer(minLength: 0)
        }
      }
    }
  }

  /// The days and their items that fit in `capacity` lines.
  private var fitted: [(String, [AgendaWidgetData.Item])] {
    var lines = 0
    var shown: [(String, [AgendaWidgetData.Item])] = []
    for (day, dayItems) in groups(items) {
      let label = entry.configuration.days > 1 ? 1 : 0
      let room = capacity - lines - label
      guard room > 0 else { break }
      let taken = Array(dayItems.prefix(room))
      shown.append((day, taken))
      lines += label + taken.count
    }
    return shown
  }

  /// One line: the item's color as a dot, when it starts, and its title, the location after it
  /// when there's room.
  private func row(_ item: AgendaWidgetData.Item) -> some View {
    let location = item.location.flatMap { $0.isEmpty ? nil : $0 }
    let place = entry.configuration.showLocations && family != .systemSmall ? location : nil
    return HStack(spacing: 5) {
      Circle()
        .fill(Color(css: item.color) ?? theme.site.button)
        .frame(width: 7, height: 7)
      Text(time(item))
        .font(SiteFont.arial(12).monospacedDigit())
        .foregroundStyle(theme.muted)
      let title = Text(item.title).foregroundStyle(theme.site.text)
      let after = Text(place.map { " · \($0)" } ?? "").foregroundStyle(theme.muted)
      Text("\(title)\(after)")
        .font(SiteFont.arial(13))
        .lineLimit(1)
    }
  }

  private func time(_ item: AgendaWidgetData.Item) -> String {
    if item.allDay == true { return "All day" }
    guard let start = item.startsAt else { return "" }
    if start <= entry.date, let end = item.endsAt { return "Now–\(Self.clock(end))" }
    return Self.clock(start)
  }

  private static let formatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate("jmm")
    formatter.amSymbol = "am"
    formatter.pmSymbol = "pm"
    return formatter
  }()

  /// "8:30am", "8pm", or "20:00" where the clock is 24-hour.
  private static func clock(_ date: Date) -> String {
    let text = formatter.string(from: date).replacingOccurrences(of: " ", with: "")
    guard text.hasSuffix("am") || text.hasSuffix("pm") else { return text }
    return text.replacingOccurrences(of: ":00", with: "")
  }

  private func groups(_ items: [AgendaWidgetData.Item]) -> [(String, [AgendaWidgetData.Item])] {
    var order: [String] = []
    var grouped: [String: [AgendaWidgetData.Item]] = [:]
    for item in items {
      let day = label(item.startsAt ?? entry.date)
      if grouped[day] == nil { order.append(day) }
      grouped[day, default: []].append(item)
    }
    return order.map { ($0, grouped[$0] ?? []) }
  }

  private func label(_ date: Date) -> String {
    let calendar = Calendar.current
    if calendar.isDateInToday(date) { return "Today" }
    if calendar.isDateInTomorrow(date) { return "Tomorrow" }
    return date.formatted(.dateTime.weekday(.wide).month().day())
  }
}

struct AgendaWidget: Widget {
  var body: some WidgetConfiguration {
    AppIntentConfiguration(kind: "BuddyAgenda", intent: AgendaWidgetIntent.self, provider: AgendaProvider()) { entry in
      AgendaWidgetView(entry: entry)
    }
    .configurationDisplayName("Agenda")
    .description("What's coming up, from one agenda or all of them.")
    .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge, .accessoryRectangular, .accessoryCircular, .accessoryInline])
    .pushHandler(BuddyWidgetPushHandler.self)
  }
}

extension AgendaWidgetData {
  static let sample = AgendaWidgetData(
    title: "Agenda",
    url: "/agenda",
    items: [
      Item(id: "1", title: "Standup", startsAt: Date().addingTimeInterval(1800), endsAt: Date().addingTimeInterval(2700), color: "#0150d5"),
      Item(id: "2", title: "Lunch", startsAt: Date().addingTimeInterval(9000), location: "Cafe Rio", color: "#34c759"),
    ],
  )
}
