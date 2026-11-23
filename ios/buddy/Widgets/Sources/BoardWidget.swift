import AppIntents
import SwiftUI
import WidgetKit

struct BoardWidgetIntent: WidgetConfigurationIntent {
  static let title: LocalizedStringResource = "Board Pet"
  static let description = IntentDescription("A board's pet, wearing its current face, and what it's thinking about.")

  @Parameter(title: "Board") var board: BoardEntity?
  @Parameter(title: "Show what it's thinking", default: true) var showThinking: Bool
  @Parameter(title: "Tint the background with the pet's color", default: true) var tinted: Bool
}

struct BoardEntry: TimelineEntry {
  var date: Date
  var data: BoardWidgetData?
  var stale: Bool
  var configuration: BoardWidgetIntent
  var signedIn: Bool
}

struct BoardProvider: AppIntentTimelineProvider {
  func placeholder(in context: Context) -> BoardEntry {
    BoardEntry(date: Date(), data: .sample, stale: false, configuration: BoardWidgetIntent(), signedIn: true)
  }

  func snapshot(for configuration: BoardWidgetIntent, in context: Context) async -> BoardEntry {
    if context.isPreview { return placeholder(in: context) }
    return await entry(configuration)
  }

  func timeline(for configuration: BoardWidgetIntent, in context: Context) async -> Timeline<BoardEntry> {
    Timeline(entries: [await entry(configuration)], policy: .after(WidgetFetch.nextRefresh(minutes: 20)))
  }

  private func entry(_ configuration: BoardWidgetIntent) async -> BoardEntry {
    guard Session.isSignedIn else {
      return BoardEntry(date: Date(), data: nil, stale: false, configuration: configuration, signedIn: false)
    }
    let id = configuration.board?.id ?? Catalog.cached.boards.first?.id ?? ""
    let (data, stale) = await WidgetFetch.load("api/ios/widgets/board/\(id)", cacheKey: "board-\(id)", as: BoardWidgetData.self)
    await ImageCache.prefetch((data?.pets ?? []).flatMap { [$0.imageUrl, $0.thinkingIcon] })
    return BoardEntry(date: Date(), data: data, stale: stale, configuration: configuration, signedIn: true)
  }
}

struct BoardWidgetView: View {
  var entry: BoardEntry
  @Environment(\.widgetFamily) private var family
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    let pet = entry.data?.pets.first
    Group {
      if !entry.signedIn {
        SignedOutView()
      } else if let data = entry.data, !data.pets.isEmpty {
        content(data)
      } else {
        WidgetNote(text: "Pick a board")
      }
    }
    .widgetBackground(tint: entry.configuration.tinted ? Color(css: pet?.color)?.opacity(0.35) : nil)
    .widgetURL(DeepLink.web(entry.data?.url ?? "/board"))
  }

  @ViewBuilder
  private func content(_ data: BoardWidgetData) -> some View {
    switch family {
    case .accessoryCircular:
      face(data.pets[0], size: 44)
    case .accessoryRectangular:
      HStack(spacing: 6) {
        face(data.pets[0], size: 40)
        VStack(alignment: .leading) {
          Text(data.pets[0].name).font(SiteFont.arial(15, bold: true))
          if let thinking = data.pets[0].thinking { Text(thinking).font(SiteFont.arial(12)).lineLimit(2) }
        }
      }
    case .accessoryInline:
      Text("\(data.pets[0].name): \(data.pets[0].thinking ?? data.pets[0].mood ?? "")")
    case .systemSmall:
      petCard(data.pets[0], faceSize: 70)
    default:
      HStack(spacing: 10) {
        ForEach(data.pets.prefix(family == .systemMedium ? 2 : 4)) { pet in
          Link(destination: DeepLink.web(pet.url ?? data.url ?? "/board")) {
            petCard(pet, faceSize: family == .systemMedium ? 64 : 90)
          }
        }
      }
    }
  }

  private func petCard(_ pet: BoardWidgetData.Pet, faceSize: CGFloat) -> some View {
    VStack(spacing: 4) {
      if entry.configuration.showThinking, let thinking = pet.thinking, !thinking.isEmpty {
        ThoughtBubble(text: thinking, icon: pet.thinkingIcon, color: Color(css: pet.color))
      }
      face(pet, size: faceSize)
      Text(pet.name)
        .font(SiteFont.arial(12, bold: true))
        .foregroundStyle(WidgetTheme.current(scheme).site.text)
        .lineLimit(1)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  @ViewBuilder
  private func face(_ pet: BoardWidgetData.Pet, size: CGFloat) -> some View {
    if let url = pet.imageUrl {
      RemoteImage(urlString: url).frame(width: size, height: size)
    } else {
      Text(pet.expression ?? "🙂").font(.system(size: size * 0.7))
    }
  }
}

/// The board's `.byte-board-dream` in pages/byte.scss: a white cloud outlined in the pet's color,
/// with the thought in bold dark text.
struct ThoughtBubble: View {
  var text: String
  var icon: String?
  var color: Color?

  /// `--bs-them-bg`, the dream's text color.
  private static let ink = Color(css: "#2A3B5F") ?? .black
  /// `--bs-accent`, the outline when the pet has no color of its own.
  private static let line = Color(css: "#3FA0FF") ?? .blue

  var body: some View {
    HStack(spacing: 4) {
      if let icon { BuddyIcon(name: icon, size: 11, color: ThoughtBubble.ink) }
      Text(text)
        .font(SiteFont.arial(11, bold: true))
        .foregroundStyle(ThoughtBubble.ink)
        .lineLimit(2)
        .minimumScaleFactor(0.7)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(Capsule().fill(.white))
    .overlay(Capsule().strokeBorder(color ?? ThoughtBubble.line, lineWidth: 2))
  }
}

struct BoardWidget: Widget {
  var body: some WidgetConfiguration {
    AppIntentConfiguration(kind: "BuddyBoard", intent: BoardWidgetIntent.self, provider: BoardProvider()) { entry in
      BoardWidgetView(entry: entry)
    }
    .configurationDisplayName("Board Pet")
    .description("The pet on a board, its face, and what it's thinking about.")
    .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    .pushHandler(BuddyWidgetPushHandler.self)
  }
}

extension BoardWidgetData {
  static let sample = BoardWidgetData(
    id: "0",
    name: "Board",
    url: "/board",
    pets: [Pet(id: "byte", name: "Byte", mood: "happy", expression: "😊", thinking: "Laundry's done!", color: "#6c6bf4")],
  )
}
