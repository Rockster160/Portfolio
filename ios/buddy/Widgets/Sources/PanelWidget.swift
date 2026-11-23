import AppIntents
import Charts
import SwiftUI
import WidgetKit

/// A widget whose whole content comes from the server: whatever a Jil task last put in the panel
/// with `Widget.set`. Title, big value, rows with progress, a chart, an image or SVG, and buttons —
/// any of them, in that order, as space allows.
struct PanelWidgetIntent: WidgetConfigurationIntent {
  static let title: LocalizedStringResource = "Panel"
  static let description = IntentDescription("A custom panel filled in by a Jil task: values, rows, charts, images and buttons.")

  @Parameter(title: "Panel") var panel: PanelEntity?
  @Parameter(title: "Show chart", default: true) var showChart: Bool
  @Parameter(title: "Show buttons", default: true) var showButtons: Bool
  @Parameter(title: "Show updated time", default: false) var showUpdated: Bool
}

struct PanelEntry: TimelineEntry {
  var date: Date
  var data: PanelData?
  var stale: Bool
  var configuration: PanelWidgetIntent
  var signedIn: Bool
}

struct PanelProvider: AppIntentTimelineProvider {
  func placeholder(in context: Context) -> PanelEntry {
    PanelEntry(date: Date(), data: .sample, stale: false, configuration: PanelWidgetIntent(), signedIn: true)
  }

  func snapshot(for configuration: PanelWidgetIntent, in context: Context) async -> PanelEntry {
    if context.isPreview { return placeholder(in: context) }
    return await entry(configuration)
  }

  func timeline(for configuration: PanelWidgetIntent, in context: Context) async -> Timeline<PanelEntry> {
    let entry = await entry(configuration)
    let minutes = (entry.data?.refreshAfter).map { max($0 / 60, 5) } ?? 30
    return Timeline(entries: [entry], policy: .after(WidgetFetch.nextRefresh(minutes: minutes)))
  }

  private func entry(_ configuration: PanelWidgetIntent) async -> PanelEntry {
    guard Session.isSignedIn else {
      return PanelEntry(date: Date(), data: nil, stale: false, configuration: configuration, signedIn: false)
    }
    let key = configuration.panel?.id ?? Catalog.cached.panels.first?.id ?? ""
    let (data, stale) = await WidgetFetch.load("api/ios/widgets/panels/\(key)", cacheKey: "panel-\(key)", as: PanelData.self)
    var images: [String?] = [data?.imageUrl, data?.svgImageUrl]
    images += (data?.buttons ?? []).map { $0.resolvedStyle?.image }
    images += (data?.rows ?? []).map(\.icon).filter { $0?.hasPrefix("http") == true }
    await ImageCache.prefetch(images)
    return PanelEntry(date: Date(), data: data, stale: stale, configuration: configuration, signedIn: true)
  }
}

struct PanelWidgetView: View {
  var entry: PanelEntry
  @Environment(\.widgetFamily) private var family
  @Environment(\.colorScheme) private var scheme

  private var theme: WidgetTheme { WidgetTheme.current(scheme) }

  /// The words on the panel: the site's text, or whatever reads on the panel's own background.
  private var ink: Color { Color(css: entry.data?.background)?.contrastingText ?? theme.site.text }

  var body: some View {
    Group {
      if !entry.signedIn {
        SignedOutView()
      } else if let data = entry.data {
        content(data)
      } else {
        WidgetNote(text: "Pick a panel, or create one with Widget.set in Jil")
      }
    }
    .foregroundStyle(ink)
    .widgetBackground(tint: Color(css: entry.data?.background))
    .widgetURL(entry.data.flatMap(panelURL))
  }

  private func panelURL(_ data: PanelData) -> URL? {
    if let action = data.action {
      switch action.kind {
      case .open: return DeepLink.web(action.value ?? "/")
      case .url: return URL(string: action.value ?? "")
      case .prompt: return DeepLink.compose(action)
      case .checkIn: return DeepLink.url(host: "check-in", query: ["id": action.value])
      default: return DeepLink.compose(ButtonAction(kind: .prompt, sendAs: action.kind, prefix: action.value))
      }
    }
    return data.url.map { DeepLink.web($0) }
  }

  @ViewBuilder
  private func content(_ data: PanelData) -> some View {
    let accent = Color(css: data.color) ?? theme.accent
    switch family {
    case .accessoryInline:
      Text([data.title, data.value ?? data.text].compactMap { $0 }.joined(separator: ": "))
    case .accessoryCircular:
      if let chart = data.chart, chart.kind == .gauge || chart.kind == .ring, let value = chart.points.last?.y {
        Gauge(value: value, in: (chart.min ?? 0)...(chart.max ?? 100)) {
          BuddyIcon(name: data.icon, size: 10)
        } currentValueLabel: {
          Text(data.value ?? String(Int(value)))
        }
        .gaugeStyle(.accessoryCircular)
      } else {
        VStack(spacing: 0) {
          BuddyIcon(name: data.icon, size: 14)
          Text(data.value ?? data.text ?? "").font(SiteFont.arial(15, bold: true)).minimumScaleFactor(0.5)
        }
      }
    case .accessoryRectangular:
      VStack(alignment: .leading, spacing: 1) {
        Text(data.title ?? "").font(SiteFont.arial(15, bold: true)).widgetAccentable()
        if let value = data.value { Text(value).font(SiteFont.arial(20, bold: true)) }
        ForEach((data.rows ?? []).prefix(data.value == nil ? 3 : 1)) { row in
          Text("\(row.label ?? "") \(row.value ?? "")").font(SiteFont.arial(12)).lineLimit(1)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    default:
      VStack(alignment: .leading, spacing: 6) {
        if data.title != nil || data.icon != nil {
          WidgetHeader(title: data.title ?? "", icon: data.icon, color: Color(css: data.color), stale: entry.stale, trailing: updatedText(data))
        }
        if let subtitle = data.subtitle {
          Text(subtitle).font(SiteFont.arial(12)).opacity(0.7).lineLimit(2)
        }
        if let value = data.value {
          Text(value).font(SiteFont.arial(family == .systemSmall ? 30 : 36, bold: true)).minimumScaleFactor(0.4).lineLimit(1)
        }
        if let text = data.text {
          Text(text).font(SiteFont.arial(14)).lineLimit(family == .systemLarge ? 8 : 3)
        }
        if let image = data.svgImageUrl ?? data.imageUrl {
          RemoteImage(urlString: image).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        if entry.configuration.showChart, let chart = data.chart {
          PanelChart(chart: chart, accent: accent, ink: ink).frame(maxHeight: .infinity)
        }
        if let rows = data.rows, !rows.isEmpty {
          ForEach(rows.prefix(rowCapacity(data))) { row in PanelRowView(row: row, accent: accent) }
        }
        Spacer(minLength: 0)
        if entry.configuration.showButtons, let buttons = data.buttons, !buttons.isEmpty {
          HStack(spacing: 6) {
            ForEach(buttons.prefix(family == .systemSmall ? 2 : 4)) { button in
              ActionButton(action: button.action, source: "widget_panel") {
                WidgetButtonFace(label: button.label, style: button.resolvedStyle, on: button.on, compact: true)
              }
            }
          }
          .frame(height: 42)
        }
      }
    }
  }

  private func rowCapacity(_ data: PanelData) -> Int {
    let base = family == .systemLarge || family == .systemExtraLarge ? 10 : 4
    return data.chart != nil || data.imageUrl != nil ? base / 2 : base
  }

  private func updatedText(_ data: PanelData) -> String? {
    guard entry.configuration.showUpdated, let updated = data.updatedAt else { return nil }
    return updated.formatted(date: .omitted, time: .shortened)
  }
}

struct PanelRowView: View {
  var row: PanelData.Row
  var accent: Color

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 5) {
        if let icon = row.icon { BuddyIcon(name: icon, size: 12, color: Color(css: row.color)) }
        Text(row.label ?? "").font(SiteFont.arial(12)).lineLimit(1)
        Spacer(minLength: 4)
        Text(row.value ?? "")
          .font(SiteFont.arial(12, bold: true))
          .foregroundStyle(Color(css: row.color).map(AnyShapeStyle.init) ?? AnyShapeStyle(.foreground))
      }
      if let detail = row.detail {
        Text(detail).font(SiteFont.arial(10)).opacity(0.7).lineLimit(1)
      }
      if let progress = row.progress {
        WidgetProgressBar(value: progress, color: Color(css: row.color) ?? accent)
      }
    }
  }
}

struct PanelChart: View {
  var chart: PanelData.Chart
  var accent: Color
  var ink: Color

  var body: some View {
    let color = Color(css: chart.color) ?? accent
    switch chart.kind {
    case .gauge, .ring:
      PanelRing(chart: chart, color: color)
    default:
      Chart(chart.points) { point in
        switch chart.kind {
        case .bar:
          BarMark(x: .value("x", point.x), y: .value("y", point.y))
            .foregroundStyle(by: .value("series", point.series ?? ""))
        case .area:
          AreaMark(x: .value("x", point.x), y: .value("y", point.y))
            .foregroundStyle(by: .value("series", point.series ?? ""))
        case .point:
          PointMark(x: .value("x", point.x), y: .value("y", point.y))
            .foregroundStyle(by: .value("series", point.series ?? ""))
        default:
          LineMark(x: .value("x", point.x), y: .value("y", point.y))
            .foregroundStyle(by: .value("series", point.series ?? ""))
            .interpolationMethod(.monotone)
        }
      }
      .chartForegroundStyleScale(range: [color] + WidgetTheme.series)
      .chartLegend(Set(chart.points.compactMap(\.series)).count > 1 ? .visible : .hidden)
      .chartYScale(domain: .automatic(includesZero: chart.min == 0))
      .chartXAxis(.hidden)
      .chartYAxis {
        AxisMarks { _ in
          AxisGridLine().foregroundStyle(ink.opacity(0.2))
          AxisValueLabel().font(SiteFont.arial(9)).foregroundStyle(ink.opacity(0.7))
        }
      }
    }
  }
}

/// A gauge or ring chart as the board draws a chore's progress: a round-capped ring over a faint
/// track of the same color, with the value in the middle.
struct PanelRing: View {
  var chart: PanelData.Chart
  var color: Color

  var body: some View {
    let value = chart.points.last?.y ?? 0
    let low = chart.min ?? 0
    let high = chart.max ?? 100
    let fraction = high > low ? min(max((value - low) / (high - low), 0), 1) : 0
    ZStack {
      Circle().stroke(color.opacity(0.25), lineWidth: 6)
      Circle()
        .trim(from: 0, to: fraction)
        .stroke(color, style: StrokeStyle(lineWidth: 6, lineCap: .round))
        .rotationEffect(.degrees(-90))
      VStack(spacing: 0) {
        Text(String(format: "%.0f", value)).font(SiteFont.arial(16, bold: true))
        if let unit = chart.unit, !unit.isEmpty {
          Text(unit).font(SiteFont.arial(9)).opacity(0.7)
        }
      }
      .minimumScaleFactor(0.5)
      .padding(8)
    }
    .aspectRatio(1, contentMode: .fit)
    .padding(3)
  }
}

struct PanelWidget: Widget {
  var body: some WidgetConfiguration {
    AppIntentConfiguration(kind: "BuddyPanel", intent: PanelWidgetIntent.self, provider: PanelProvider()) { entry in
      PanelWidgetView(entry: entry)
    }
    .configurationDisplayName("Panel")
    .description("Anything a Jil task puts in a panel: values, rows, charts, images, buttons.")
    .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    .pushHandler(BuddyWidgetPushHandler.self)
  }
}

extension PanelData {
  static let sample = PanelData(
    key: "sample",
    title: "Water",
    icon: "sf:drop.fill",
    color: "#32ade6",
    value: "48 oz",
    rows: [Row(label: "Goal", value: "96 oz", progress: 0.5)],
    chart: Chart(kind: .bar, points: (1...7).map { Chart.Point(x: "\($0)", y: Double($0 * 10)) }),
  )
}
