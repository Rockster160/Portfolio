import AppIntents
import SwiftUI
import WidgetKit

/// Hot links and a chart, each widget set up on its own under Edit Widget: which panel to chart
/// (any a Jil task fills with Widget.set) and which hot link goes in each place. The links are
/// numbered slots because iOS needs each as its own parameter; their order is the slots' order,
/// and none picked shows every hot link.
struct HotLinksWidgetIntent: WidgetConfigurationIntent {
  static let title: LocalizedStringResource = "Hot links"

  static var parameterSummary: some ParameterSummary {
    When(widgetFamily: .equalTo, .systemSmall) {
      Summary {
        \.$chart
        \.$showLinks
        \.$link1
        \.$link2
        \.$link3
        \.$link4
      }
    } otherwise: {
      When(widgetFamily: .equalTo, .systemMedium) {
        Summary {
          \.$chart
          \.$showLinks
          \.$link1
          \.$link2
          \.$link3
          \.$link4
          \.$link5
          \.$link6
          \.$link7
          \.$link8
        }
      } otherwise: {
        Summary {
          \.$chart
          \.$showLinks
          \.$link1
          \.$link2
          \.$link3
          \.$link4
          \.$link5
          \.$link6
          \.$link7
          \.$link8
          \.$link9
          \.$link10
          \.$link11
          \.$link12
          \.$link13
          \.$link14
          \.$link15
          \.$link16
        }
      }
    }
  }

  @Parameter(title: "Chart") var chart: PanelEntity?
  @Parameter(title: "Show hot links", default: true) var showLinks: Bool
  @Parameter(title: "Link 1") var link1: HotLinkEntity?
  @Parameter(title: "Link 2") var link2: HotLinkEntity?
  @Parameter(title: "Link 3") var link3: HotLinkEntity?
  @Parameter(title: "Link 4") var link4: HotLinkEntity?
  @Parameter(title: "Link 5") var link5: HotLinkEntity?
  @Parameter(title: "Link 6") var link6: HotLinkEntity?
  @Parameter(title: "Link 7") var link7: HotLinkEntity?
  @Parameter(title: "Link 8") var link8: HotLinkEntity?
  @Parameter(title: "Link 9") var link9: HotLinkEntity?
  @Parameter(title: "Link 10") var link10: HotLinkEntity?
  @Parameter(title: "Link 11") var link11: HotLinkEntity?
  @Parameter(title: "Link 12") var link12: HotLinkEntity?
  @Parameter(title: "Link 13") var link13: HotLinkEntity?
  @Parameter(title: "Link 14") var link14: HotLinkEntity?
  @Parameter(title: "Link 15") var link15: HotLinkEntity?
  @Parameter(title: "Link 16") var link16: HotLinkEntity?

  /// The links in their places, nil where a slot is empty: the slots picked, or every hot link
  /// when none is. A picked link since removed leaves its place empty.
  var shownLinks: [HotLink?] {
    guard showLinks else { return [] }
    let slots = [link1, link2, link3, link4, link5, link6, link7, link8,
                 link9, link10, link11, link12, link13, link14, link15, link16]
    let all = HotLink.all
    guard let last = slots.lastIndex(where: { $0 != nil }) else { return all }
    let placed = slots[...last].map { slot in slot.flatMap { entity in all.first { $0.id == entity.id } } }
    return placed.contains { $0 != nil } ? placed : all
  }
}

struct HotLinksEntry: TimelineEntry {
  var date: Date
  var links: [HotLink?]
  var chartName: String?
  var panel: PanelData?
  var stale: Bool
  var signedIn: Bool

  var hasLinks: Bool { links.contains { $0 != nil } }
}

struct HotLinksProvider: AppIntentTimelineProvider {
  func placeholder(in context: Context) -> HotLinksEntry {
    HotLinksEntry(date: Date(), links: HotLink.all, chartName: nil, panel: nil, stale: false, signedIn: true)
  }

  func snapshot(for configuration: HotLinksWidgetIntent, in context: Context) async -> HotLinksEntry {
    await entry(configuration)
  }

  func timeline(for configuration: HotLinksWidgetIntent, in context: Context) async -> Timeline<HotLinksEntry> {
    let entry = await entry(configuration)
    let minutes = (entry.panel?.refreshAfter).map { max($0 / 60, 5) } ?? 60
    return Timeline(entries: [entry], policy: .after(WidgetFetch.nextRefresh(minutes: minutes)))
  }

  private func entry(_ configuration: HotLinksWidgetIntent) async -> HotLinksEntry {
    guard Session.isSignedIn else {
      return HotLinksEntry(date: Date(), links: [], chartName: nil, panel: nil, stale: false, signedIn: false)
    }
    var panel: PanelData?
    var stale = false
    if let chart = configuration.chart {
      (panel, stale) = await WidgetFetch.load("api/ios/widgets/panels/\(chart.id)", cacheKey: "panel-\(chart.id)", as: PanelData.self)
    }
    return HotLinksEntry(
      date: Date(),
      links: configuration.shownLinks,
      chartName: configuration.chart?.name,
      panel: panel,
      stale: stale,
      signedIn: true,
    )
  }
}

struct HotLinksWidgetView: View {
  var entry: HotLinksEntry
  @Environment(\.widgetFamily) private var family

  var body: some View {
    Group {
      if !entry.signedIn {
        SignedOutView()
      } else if entry.chartName != nil {
        withChart
      } else if !entry.hasLinks {
        WidgetNote(text: "No hot links yet")
      } else {
        grid(columns: family == .systemSmall ? 2 : 4, rows: family == .systemLarge ? 4 : 2)
      }
    }
    .widgetBackground()
  }

  /// The chart alone in a small widget or with no links; beside a 2 by 2 of links in a medium;
  /// over a row of 4 in a large.
  @ViewBuilder
  private var withChart: some View {
    let tile = ChartTile(name: entry.chartName ?? "", panel: entry.panel, stale: entry.stale)
    if family == .systemSmall || !entry.hasLinks {
      tile
    } else if family == .systemMedium {
      HStack(spacing: 8) {
        tile
        grid(columns: 2, rows: 2)
      }
    } else {
      VStack(spacing: 8) {
        tile
        grid(columns: 4, rows: 1).frame(height: 64)
      }
    }
  }

  /// The links in even rows, an empty slot keeping each the same size while there are fewer links
  /// than the space holds.
  private func grid(columns: Int, rows: Int) -> some View {
    let links = Array(entry.links.prefix(columns * rows))
    return VStack(spacing: 6) {
      ForEach(0..<rows, id: \.self) { row in
        HStack(spacing: 6) {
          ForEach(0..<columns, id: \.self) { column in
            let index = row * columns + column
            if index < links.count, let link = links[index] {
              ActionButton(action: link.action, source: "widget_hot_links") {
                WidgetButtonFace(label: link.title, style: Styled(icon: "sf:\(link.icon)"), compact: true)
              }
            } else {
              Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
          }
        }
      }
    }
  }
}

/// The picked panel's title, value and chart, opening the panel's own page when tapped.
struct ChartTile: View {
  var name: String
  var panel: PanelData?
  var stale: Bool
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    let theme = WidgetTheme.current(scheme)
    let accent = Color(css: panel?.color) ?? theme.accent
    VStack(alignment: .leading, spacing: 4) {
      WidgetHeader(title: panel?.title ?? name, icon: panel?.icon, color: Color(css: panel?.color), stale: stale)
      if let value = panel?.value {
        Text(value).font(SiteFont.arial(22, bold: true)).minimumScaleFactor(0.4).lineLimit(1)
      }
      if let chart = panel?.chart {
        PanelChart(chart: chart, accent: accent, ink: theme.site.text).frame(maxHeight: .infinity)
      }
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}

struct HotLinksWidget: Widget {
  var body: some WidgetConfiguration {
    AppIntentConfiguration(kind: "BuddyHotLinks", intent: HotLinksWidgetIntent.self, provider: HotLinksProvider()) { entry in
      HotLinksWidgetView(entry: entry)
    }
    .configurationDisplayName("Hot links")
    .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
  }
}
