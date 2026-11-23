import ActivityKit
import Foundation

struct SignInReply: Decodable {
  var token: String
  var device: DeviceInfo
  var user: UserInfo
  var primaryConversationId: Int?
}

struct DeviceInfo: Codable, Equatable {
  var id: Int
  var name: String
}

struct UserInfo: Codable, Equatable {
  var id: Int
  var username: String
}

/// What pickers offer: everything a hot link, widget or intent can point at.
struct Catalog: Codable, Equatable {
  struct Item: Codable, Equatable, Hashable, Identifiable {
    var id: String
    var name: String
    var subtitle: String?
    var icon: String?
    var color: String?
  }

  var lists: [Item] = []
  var tasks: [Item] = []
  var routines: [Item] = []
  var boards: [Item] = []
  var panels: [Item] = []
  var agendas: [Item] = []
  var conversations: [Item] = []
  var places: [Place] = []
  var primaryConversationId: Int?
  var webPaths: [String: String] = [:]

  struct Place: Codable, Equatable, Hashable, Identifiable {
    var id: String
    var name: String
    var lat: Double
    var lng: Double
    var radius: Double?
  }

  static var cached: Catalog {
    get { SharedStore.load(Catalog.self, key: SharedStore.Key.catalog) ?? Catalog() }
    set { SharedStore.save(newValue, key: SharedStore.Key.catalog) }
  }

  @discardableResult
  static func refresh() async throws -> Catalog {
    let catalog = try await APIClient.shared.get("api/ios/catalog", as: Catalog.self)
    cached = catalog
    return catalog
  }
}

// MARK: - Widget payloads

/// A colored, iconed thing the server styles: a list's big button, a panel button, a chip.
struct Styled: Codable, Equatable, Hashable {
  var icon: String?
  var color: String?
  var background: String?
  var image: String?
}

/// What a press does. One shape for hot links, widget buttons, panel buttons and notification
/// actions, so anything that can be pressed can do anything.
struct ButtonAction: Codable, Equatable, Hashable {
  enum Kind: String, Codable, CaseIterable, Identifiable {
    case open
    case command
    case buddy
    case task
    case routine
    case trigger
    case checkIn = "check_in"
    case prompt
    case listToggle = "list_toggle"
    case url

    var id: String { rawValue }

    var title: String {
      switch self {
      case .open: return "Open a screen"
      case .command: return "Run a command"
      case .buddy: return "Message Buddy"
      case .task: return "Run a Jil task"
      case .routine: return "Run a routine"
      case .trigger: return "Fire a Jil trigger"
      case .checkIn: return "Open a check-in"
      case .prompt: return "Ask, then send"
      case .listToggle: return "Toggle a list item"
      case .url: return "Open a link"
      }
    }

    /// Kinds that need nothing from the app being open.
    var runsInBackground: Bool {
      switch self {
      case .command, .buddy, .task, .routine, .trigger, .listToggle: return true
      default: return false
      }
    }
  }

  var kind: Kind
  /// The command text, task id, trigger key, path, URL… depending on kind.
  var value: String?
  /// For `.prompt`: what the text is sent as once typed (command or buddy), and the placeholder.
  var sendAs: Kind?
  var placeholder: String?
  /// Prefix glued in front of whatever's typed, e.g. "Take me to ".
  var prefix: String?
  var data: JSONValue?
  /// Wait for the reply and show it, instead of queueing quietly.
  var inline: Bool?

  init(kind: Kind, value: String? = nil, sendAs: Kind? = nil, placeholder: String? = nil, prefix: String? = nil, data: JSONValue? = nil, inline: Bool? = nil) {
    self.kind = kind
    self.value = value
    self.sendAs = sendAs
    self.placeholder = placeholder
    self.prefix = prefix
    self.data = data
    self.inline = inline
  }
}

struct ListWidgetData: Codable, Equatable {
  struct Item: Codable, Equatable, Identifiable {
    var id: Int
    var name: String
    var section: String?
    var checked: Bool?
    var important: Bool?
    var icon: String?
    var color: String?
  }

  struct Button: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var state: String?
    var on: Bool?
    var style: Styled?
    var action: ButtonAction?
  }

  var id: Int
  var name: String
  var url: String?
  var count: Int?
  var items: [Item]
  var buttons: [Button]?
}

struct TaskButtonsData: Codable, Equatable {
  var buttons: [ListWidgetData.Button]
}

struct AgendaWidgetData: Codable, Equatable {
  struct Item: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    var startsAt: Date?
    var endsAt: Date?
    var allDay: Bool?
    var location: String?
    var color: String?
    var icon: String?
    var calendar: String?
    var url: String?
  }

  var title: String?
  var url: String?
  var items: [Item]
}

struct BoardWidgetData: Codable, Equatable {
  struct Pet: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var mood: String?
    var expression: String?
    var imageUrl: String?
    var thinking: String?
    var thinkingIcon: String?
    var color: String?
    var url: String?
  }

  var id: String
  var name: String
  var url: String?
  var pets: [Pet]
}

/// A server-described widget. Jil fills it in (`Widget.set`), so a panel can show anything a task
/// can compute, and the app needs no update to show something new.
struct PanelData: Codable, Equatable {
  struct Row: Codable, Equatable, Identifiable {
    var id: String { (label ?? "") + (value ?? "") + (icon ?? "") }
    @Loose var label: String? = nil
    @Loose var value: String? = nil
    @Loose var detail: String? = nil
    var icon: String?
    var color: String?
    var progress: Double?
  }

  struct Button: Codable, Equatable, Identifiable {
    var id: String { (label ?? "") + (style?.icon ?? "") + (state ?? "") }
    @Loose var label: String? = nil
    @Loose var state: String? = nil
    var on: Bool?
    var style: Styled?
    /// Styles keyed by state value, picked by `state` — how a button turns green when the door is
    /// open without the task having to restyle it.
    var styles: [String: Styled]?
    var action: ButtonAction?

    var resolvedStyle: Styled? {
      if let state, let match = styles?[state] { return match }
      if let on, let match = styles?[on ? "on" : "off"] { return match }
      return style
    }
  }

  struct Chart: Codable, Equatable {
    enum Kind: String, Codable { case line, bar, area, point, ring, gauge }
    struct Point: Codable, Equatable, Identifiable {
      var id: String { "\(series ?? "")-\(x)" }
      var x: String
      var y: Double
      var series: String?

      init(x: String, y: Double, series: String? = nil) {
        self.x = x
        self.y = y
        self.series = series
      }

      /// Jil hands over whatever it computed: numbers as strings, dates as x values.
      init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        x = (try? container.decode(Loose.self, forKey: .x))?.wrappedValue ?? ""
        y = (try? container.decode(JSONValue.self, forKey: .y))?.double ?? 0
        series = (try? container.decode(Loose.self, forKey: .series))?.wrappedValue
      }
    }
    var kind: Kind
    var points: [Point]
    var min: Double?
    var max: Double?
    var color: String?
    var unit: String?
  }

  var key: String
  @Loose var title: String? = nil
  @Loose var subtitle: String? = nil
  var icon: String?
  var color: String?
  var background: String?
  @Loose var text: String? = nil
  @Loose var value: String? = nil
  var rows: [Row]?
  var buttons: [Button]?
  var chart: Chart?
  var imageUrl: String?
  var svg: String?
  /// The server's PNG render of `svg`, since widgets can't draw SVG.
  var svgImageUrl: String?
  var url: String?
  var action: ButtonAction?
  var updatedAt: Date?
  /// Seconds the widget may show this before asking again.
  var refreshAfter: Double?
}

struct TimerData: Codable, Equatable, Identifiable {
  var id: Int
  var name: String
  var kind: String?
  var icon: String?
  var color: String?
  var endsAt: Date?
  var startedAt: Date?
  var pausedRemaining: Double?
  var state: String
  /// The bundled sound it rings with (App/Resources/Sounds, without .caf), matching the page.
  var sound: String?
  var url: String?

  var alertSound: ActivityKit.AlertConfiguration.AlertSound {
    sound.map { .named("\($0).caf") } ?? .default
  }
}

/// A string field that also accepts a number or a boolean, for JSON a Jil task wrote, where `48`
/// and `"48"` mean the same thing. A missing key is nil rather than a decoding failure.
@propertyWrapper
struct Loose: Codable, Equatable, Hashable {
  var wrappedValue: String?

  init(wrappedValue: String?) {
    self.wrappedValue = wrappedValue
  }

  init(from decoder: Decoder) throws {
    wrappedValue = (try? decoder.singleValueContainer().decode(JSONValue.self))?.string
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(wrappedValue)
  }
}

extension KeyedDecodingContainer {
  func decode(_ type: Loose.Type, forKey key: Key) throws -> Loose {
    try decodeIfPresent(type, forKey: key) ?? Loose(wrappedValue: nil)
  }
}
