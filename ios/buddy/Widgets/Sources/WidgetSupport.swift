import SwiftUI
import WidgetKit

/// Every widget fetches through here: live from the server when it can, the last good copy when it
/// can't, so a widget on a phone with no signal shows stale data rather than an error.
enum WidgetFetch {
  static func load<T: Codable>(_ path: String, query: [String: String?] = [:], cacheKey: String, as type: T.Type) async -> (T?, Bool) {
    let file = "widget-\(cacheKey).json"
    do {
      let fresh = try await APIClient.shared.get(path, query: query, as: T.self)
      SharedStore.mutateFile(Optional<T>.self, name: file, empty: nil) { $0 = fresh }
      return (fresh, false)
    } catch {
      let cached = SharedStore.readFile(Optional<T>.self, name: file) ?? nil
      return (cached, true)
    }
  }

  /// How long a widget waits before asking again. WidgetKit spends a daily budget, so the
  /// server's push reloads do the real work and this is the backstop.
  static func nextRefresh(minutes: Double = 15) -> Date {
    Date().addingTimeInterval(minutes * 60)
  }
}

/// The site's colors for whichever mode the account is in: SitePalette, plus the few page colors
/// it doesn't carry, taken from the stylesheets named beside each one.
struct WidgetTheme {
  var site: SitePalette
  var dark: Bool

  static func current(_ scheme: ColorScheme) -> WidgetTheme {
    let site = SitePalette.current(scheme)
    // `current` hands back one of the two palettes whole, so its page color says which.
    return WidgetTheme(site: site, dark: site.page == SitePalette.dark.page)
  }

  /// A title, value or default tint with no color of its own: the card title's blue on a light
  /// card, and the page text on a dark one, where the darker title blue would vanish.
  var accent: Color { dark ? site.text : site.cardTitle }
  /// Times, counts and other second-rank text, as the agenda's `.agenda-item-time` fades them.
  var muted: Color { site.text.opacity(0.7) }

  /// `$blue-l2`: a tint that still reads on the Dynamic Island's black.
  static let blueL2 = Color(css: "#5695FF") ?? .blue
  /// `gold`: `.list-item-config .important` in pages/list.scss.
  static let important = Color(css: "#FFD700") ?? .yellow
  /// `$base-complementary`: the site's one warm accent, for something waiting on attention.
  static let complementary = Color(css: "#FE9F00") ?? .orange
  /// `$t-success` in pages/timers.scss: a button whose task is on.
  static let on = Color(css: "#3FB950") ?? .green
  /// Extra chart series after the panel's own color: `$base-complementary`, `$dpl-purple`,
  /// `$flash-notice-bg` and `$danger`.
  static let series = ["#FE9F00", "#8168B1", "#009DB2", "#F6433D"].compactMap { Color(css: $0) }
}

extension Color {
  /// Sass's `lighten` (positive) and `darken` (negative): moves HSL lightness by `amount`, which is
  /// how the site derives a button's edge and text shadow from its color.
  func sassLightness(_ amount: Double) -> Color {
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alpha: CGFloat = 0
    guard UIColor(self).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return self }
    let high = max(red, green, blue)
    let low = min(red, green, blue)
    let spread = high - low
    let lightness = (high + low) / 2
    var hue: CGFloat = 0
    var saturation: CGFloat = 0
    if spread > 0 {
      saturation = lightness > 0.5 ? spread / (2 - high - low) : spread / (high + low)
      switch high {
      case red: hue = (green - blue) / spread + (green < blue ? 6 : 0)
      case green: hue = (blue - red) / spread + 2
      default: hue = (red - green) / spread + 4
      }
      hue /= 6
    }
    let target = min(max(lightness + amount, 0), 1)
    let upper = target < 0.5 ? target * (1 + saturation) : target + saturation - target * saturation
    let lower = 2 * target - upper
    func channel(_ offset: CGFloat) -> Double {
      var position = hue + offset
      if position < 0 { position += 1 }
      if position > 1 { position -= 1 }
      if position < 1 / 6 { return lower + (upper - lower) * 6 * position }
      if position < 1 / 2 { return upper }
      if position < 2 / 3 { return lower + (upper - lower) * (2 / 3 - position) * 6 }
      return lower
    }
    return Color(.sRGB, red: channel(1 / 3), green: channel(0), blue: channel(-1 / 3), opacity: alpha)
  }

  /// The site's buttons are always white-lettered, so their darker text shadow only belongs under
  /// light words; under dark words on a pale task color it would read as a blur.
  func textShadow(_ shadow: Color) -> Color {
    contrastingText == .black ? shadow : .clear
  }
}

struct SignedOutView: View {
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    let theme = WidgetTheme.current(scheme)
    VStack(spacing: 4) {
      Text("Buddy").font(SiteFont.arial(16, bold: true)).foregroundStyle(theme.accent)
      Text("Open Buddy to log in").font(SiteFont.arial(12)).foregroundStyle(theme.site.label)
    }
    .multilineTextAlignment(.center)
  }
}

/// A line of quiet text where a widget has nothing to show yet.
struct WidgetNote: View {
  var text: String
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    Text(text)
      .font(SiteFont.arial(12))
      .foregroundStyle(WidgetTheme.current(scheme).muted)
      .multilineTextAlignment(.center)
  }
}

struct StaleBadge: View {
  var stale: Bool
  var color: Color

  var body: some View {
    if stale {
      BuddyIcon(name: "ti-mdi-cloud_off_outline", size: 11, color: color.opacity(0.8))
    }
  }
}

/// The site's `.form-title`: a band of the card title's blue across the top of the card, white
/// words on it. It reaches past the widget's content margins to the card's edges, and the
/// content under it starts where the band ends.
struct WidgetHeader: View {
  var title: String
  var icon: String?
  var color: Color?
  var stale = false
  var trailing: String?
  @Environment(\.colorScheme) private var scheme
  @Environment(\.widgetContentMargins) private var margins

  var body: some View {
    let band = color ?? WidgetTheme.current(scheme).site.cardTitle
    let ink = color?.contrastingText ?? .white
    HStack(spacing: 5) {
      if let icon { BuddyIcon(name: icon, size: 12, color: ink) }
      Text(title).font(SiteFont.arial(13, bold: true)).foregroundStyle(ink).lineLimit(1)
      Spacer(minLength: 2)
      StaleBadge(stale: stale, color: ink)
      if let trailing {
        Text(trailing).font(SiteFont.arial(11, bold: true)).foregroundStyle(ink.opacity(0.85))
      }
    }
    .padding(.vertical, 4)
    .background {
      band.padding(EdgeInsets(top: -margins.top, leading: -margins.leading, bottom: 0, trailing: -margins.trailing))
    }
    .padding(.top, -margins.top)
  }
}

/// A task button the way the site draws a `.btn`: a flat fill with 6pt corners, a lighter edge
/// under it, a darker shadow under the words, and Arial bold. The fill is the task's own color
/// when it has one and the site's button blue when it doesn't.
struct WidgetButtonFace: View {
  var label: String?
  var style: Styled?
  var on: Bool?
  var compact = false
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    let site = WidgetTheme.current(scheme).site
    let custom = Color(css: style?.background) ?? Color(css: style?.color)
    let background = custom ?? (on == true ? WidgetTheme.on : site.button)
    let foreground = (style?.background != nil ? Color(css: style?.color) : nil) ?? background.contrastingText
    let edge = custom == nil && on != true ? site.buttonEdge : background.sassLightness(0.15)
    let shadow = custom == nil && on != true ? site.buttonTextShadow : background.sassLightness(-0.15)
    VStack(spacing: 4) {
      if let image = style?.image {
        RemoteImage(urlString: image).frame(width: compact ? 22 : 30, height: compact ? 22 : 30)
      } else if style?.icon != nil || label == nil {
        BuddyIcon(name: style?.icon, fallbackText: label, size: compact ? 18 : 24, color: foreground)
      }
      if let label, !label.isEmpty {
        Text(label)
          .font(SiteFont.arial(compact ? 11 : 14, bold: true))
          .lineLimit(2)
          .minimumScaleFactor(0.6)
          .multilineTextAlignment(.center)
          .foregroundStyle(foreground)
          .shadow(color: foreground.textShadow(shadow), radius: 0, x: 0, y: 1)
      }
    }
    .padding(6)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(RoundedRectangle(cornerRadius: 6).fill(background))
    .background(RoundedRectangle(cornerRadius: 6).fill(edge).offset(y: 1))
  }
}

/// A task button the way the board draws one (`.byte-board-circle` in pages/byte.scss): a flat dark
/// disc washed with the button's color, a ring of it, the icon in the middle and the name under it.
/// It's always the one size, like an app icon, so a bigger widget holds more of them rather than
/// bigger ones.
struct WidgetCircleButton: View {
  var label: String?
  var icon: String?
  var image: String?
  var color: Color?
  var on: Bool?
  var size: CGFloat = WidgetCircleButton.size
  var showsLabel = true
  @Environment(\.colorScheme) private var scheme

  /// Two rows of these with their names fill a medium widget's height.
  static let size: CGFloat = 46
  /// `.byte-board-circle`'s fill.
  static let disc = Color(css: "#0F1B33") ?? .black
  /// `.byte-board-cell[data-kind="task"]`'s color, for a button with none of its own.
  static let task = Color(css: "#0EA5E9") ?? .blue

  /// A Jil task's button, wearing its monitor's last icon and color.
  init(label: String?, style: Styled?, on: Bool?, size: CGFloat = WidgetCircleButton.size, showsLabel: Bool = true) {
    self.label = label
    icon = style?.icon
    image = style?.image
    color = Color(css: style?.background) ?? Color(css: style?.color)
    self.on = on
    self.size = size
    self.showsLabel = showsLabel
  }

  init(label: String?, icon: String?, color: Color?, size: CGFloat = WidgetCircleButton.size) {
    self.label = label
    self.icon = icon
    self.color = color
    self.size = size
  }

  var body: some View {
    let tint = color ?? (on == true ? WidgetTheme.on : WidgetCircleButton.task)
    let ink = SitePalette.dark.text
    VStack(spacing: 3) {
      ZStack {
        Circle().fill(WidgetCircleButton.disc)
        Circle().fill(tint.opacity(on == true ? 0.4 : 0.16))
        Circle().strokeBorder(tint.opacity(on == false ? 0.3 : 0.75), lineWidth: max(size / 18, 1.5))
        if let image {
          RemoteImage(urlString: image).frame(width: size * 0.56, height: size * 0.56)
        } else {
          BuddyIcon(name: icon, fallbackText: label, size: size * 0.46, color: ink)
        }
      }
      .frame(width: size, height: size)
      if showsLabel, let label, !label.isEmpty {
        Text(label)
          .font(SiteFont.arial(10, bold: true))
          .foregroundStyle(WidgetTheme.current(scheme).site.text)
          .lineLimit(1)
          .minimumScaleFactor(0.8)
      }
    }
  }
}

/// Circle buttons placed the way the Home Screen places icons: a fixed grid, each in its own
/// spot, an empty spot left empty rather than the rest stretching into it.
struct WidgetCircleGrid<Cell: View>: View {
  var count: Int
  var columns: Int
  var rows: Int
  @ViewBuilder var cell: (Int) -> Cell

  var body: some View {
    VStack(spacing: 0) {
      ForEach(0..<rows, id: \.self) { row in
        HStack(spacing: 0) {
          ForEach(0..<columns, id: \.self) { column in
            let index = row * columns + column
            Group {
              if index < count { cell(index) } else { Color.clear }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
          }
        }
      }
    }
  }
}

extension WidgetFamily {
  /// How many circle buttons across and down a widget of this size holds; one row fewer under a
  /// title in the two smaller sizes.
  func circleGrid(titled: Bool = false) -> (columns: Int, rows: Int) {
    switch self {
    case .systemSmall: return (2, titled ? 1 : 2)
    case .systemMedium: return (4, titled ? 1 : 2)
    case .systemLarge: return (4, 4)
    case .systemExtraLarge: return (8, 4)
    case .accessoryRectangular: return (3, 1)
    default: return (1, 1)
    }
  }
}

/// The same `.btn` for a real Button, as the Live Activity's timer controls use.
struct WidgetButtonStyle: ButtonStyle {
  var color: Color

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(SiteFont.arial(13, bold: true))
      .foregroundStyle(color.contrastingText)
      .shadow(color: color.contrastingText.textShadow(color.sassLightness(-0.15)), radius: 0, x: 0, y: 1)
      .padding(.vertical, 7)
      .padding(.horizontal, 12)
      .frame(maxWidth: .infinity)
      .background(RoundedRectangle(cornerRadius: 6).fill(configuration.isPressed ? color.sassLightness(-0.2) : color))
      .background(RoundedRectangle(cornerRadius: 6).fill(color.sassLightness(0.15)).offset(y: 1))
  }
}

/// A thin bar for a row's progress, in place of the system's ProgressView.
struct WidgetProgressBar: View {
  var value: Double
  var color: Color

  var body: some View {
    GeometryReader { proxy in
      ZStack(alignment: .leading) {
        Capsule().fill(color.opacity(0.25))
        Capsule().fill(color).frame(width: proxy.size.width * min(max(value, 0), 1))
      }
    }
    .frame(height: 4)
  }
}

/// A button in a widget: background kinds run in place through RunActionIntent, kinds that need the
/// app open it through a link.
struct ActionButton<Label: View>: View {
  var action: ButtonAction?
  var source: String
  @ViewBuilder var label: () -> Label

  var body: some View {
    if let action {
      if action.kind.runsInBackground && action.inline != true {
        Button(intent: RunActionIntent(action, source: source)) { label() }
          .buttonStyle(.plain)
      } else {
        Link(destination: destination(action)) { label() }
      }
    } else {
      label()
    }
  }

  private func destination(_ action: ButtonAction) -> URL {
    switch action.kind {
    case .prompt: return DeepLink.compose(action)
    case .checkIn: return DeepLink.url(host: "check-in", query: ["id": action.value])
    case .url: return URL(string: action.value ?? "") ?? DeepLink.web("/")
    case .open: return DeepLink.web(action.value ?? "/")
    default: return DeepLink.compose(ButtonAction(kind: .prompt, sendAs: action.kind, prefix: action.value, inline: true))
    }
  }
}

/// Which of the site's two backgrounds a widget sits on: the page itself, for a widget whose
/// contents are cards of their own (list items, agenda rows), or a `.form` card.
enum WidgetSurface {
  case page
  case card
}

extension View {
  /// The container background WidgetKit requires, in one place so every widget can be themed. A
  /// tint (a panel's background, a pet's color) is laid over the site's color, not instead of it.
  func widgetBackground(_ surface: WidgetSurface = .card, tint: Color? = nil) -> some View {
    modifier(WidgetBackground(surface: surface, tint: tint))
  }
}

private struct WidgetBackground: ViewModifier {
  var surface: WidgetSurface
  var tint: Color?
  @Environment(\.colorScheme) private var scheme

  func body(content: Content) -> some View {
    let site = WidgetTheme.current(scheme).site
    content.containerBackground(for: .widget) {
      ZStack {
        surface == .page ? site.page : site.card
        if let tint { tint }
      }
    }
  }
}
