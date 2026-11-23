import SwiftUI
import UIKit

extension Color {
  /// Reads the colors the server hands out: `#RGB`, `#RRGGBB`, `#RRGGBBAA`, `rgb()/rgba()`, or a
  /// handful of CSS names. Anything unreadable is nil so the caller's default shows instead.
  init?(css raw: String?) {
    guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !value.isEmpty else { return nil }
    if let named = Color.cssNames[value] {
      value = named
    }
    if value.hasPrefix("rgb") {
      let numbers = value.drop { $0 != "(" }.dropFirst().prefix { $0 != ")" }
        .split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: "")) ?? 0 }
      guard numbers.count >= 3 else { return nil }
      self = Color(.sRGB, red: numbers[0] / 255, green: numbers[1] / 255, blue: numbers[2] / 255, opacity: numbers.count > 3 ? numbers[3] : 1)
      return
    }
    guard value.hasPrefix("#") else { return nil }
    var hex = String(value.dropFirst())
    if hex.count == 3 || hex.count == 4 { hex = hex.map { "\($0)\($0)" }.joined() }
    guard let number = UInt64(hex, radix: 16) else { return nil }
    let red, green, blue, alpha: Double
    switch hex.count {
    case 6:
      red = Double((number >> 16) & 0xFF) / 255
      green = Double((number >> 8) & 0xFF) / 255
      blue = Double(number & 0xFF) / 255
      alpha = 1
    case 8:
      red = Double((number >> 24) & 0xFF) / 255
      green = Double((number >> 16) & 0xFF) / 255
      blue = Double((number >> 8) & 0xFF) / 255
      alpha = Double(number & 0xFF) / 255
    default:
      return nil
    }
    self = Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
  }

  private static let cssNames: [String: String] = [
    "red": "#ff3b30", "orange": "#ff9500", "yellow": "#ffcc00", "green": "#34c759",
    "mint": "#00c7be", "teal": "#30b0c7", "cyan": "#32ade6", "blue": "#0150d5",
    "indigo": "#5856d6", "purple": "#af52de", "pink": "#ff2d55", "brown": "#a2845e",
    "gray": "#8e8e93", "grey": "#8e8e93", "black": "#000000", "white": "#ffffff",
    "gold": "#ffd60a", "lime": "#a4e400", "navy": "#001f5b", "maroon": "#800000",
  ]

  /// Readable text over this color.
  var contrastingText: Color {
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alpha: CGFloat = 0
    guard UIColor(self).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return .white }
    let luminance = 0.299 * red + 0.587 * green + 0.114 * blue
    return luminance > 0.6 ? .black : .white
  }
}

/// Draws any icon string the server uses, the same way the site does: a `ti-*` glyph from the
/// bundled terminess font, an SF Symbol, an emoji, or a remote image.
struct BuddyIcon: View {
  var name: String?
  var fallbackText: String?
  var size: CGFloat = 18
  var color: Color?

  var body: some View {
    Group {
      if let name, !name.isEmpty {
        if let glyph = IconFont.glyph(name) {
          Text(glyph)
            .font(.custom(IconFont.fontName, size: size))
        } else if name.hasPrefix("sf:") || IconFont.isSymbol(name) {
          Image(systemName: name.hasPrefix("sf:") ? String(name.dropFirst(3)) : name)
            .font(.system(size: size * 0.9, weight: .semibold))
        } else if name.hasPrefix("http") || name.hasPrefix("/") || name.hasPrefix("data:image") {
          RemoteImage(urlString: name)
            .frame(width: size * 1.2, height: size * 1.2)
        } else {
          Text(name).font(.system(size: size))
        }
      } else if let fallbackText, let first = fallbackText.first {
        Text(String(first).uppercased())
          .font(.system(size: size, weight: .bold, design: .rounded))
      }
    }
    .foregroundStyle(color ?? .primary)
  }
}

enum IconFont {
  static let fontName = "TerminessTTFNerdFontCompl-Medium"

  private static let map: [String: Int] = {
    let bundles = [Bundle.main] + Bundle.allBundles
    for bundle in bundles {
      if let url = bundle.url(forResource: "ti_icons", withExtension: "json"),
         let data = try? Data(contentsOf: url),
         let decoded = try? JSONDecoder().decode([String: Int].self, from: data) {
        return decoded
      }
    }
    return [:]
  }()

  static func glyph(_ name: String) -> String? {
    let key = name.hasPrefix("ti ") ? String(name.dropFirst(3)) : name
    guard key.hasPrefix("ti-"), let code = map[key], let scalar = UnicodeScalar(code) else { return nil }
    return String(Character(scalar))
  }

  static func isSymbol(_ name: String) -> Bool {
    name.range(of: "^[a-z0-9]+(\\.[a-z0-9]+)+$", options: .regularExpression) != nil && UIImage(systemName: name) != nil
  }
}

/// Images in widgets can't load lazily, so widget providers pre-fetch into `ImageCache`; this view
/// reads that cache first and only falls back to AsyncImage inside the app.
struct RemoteImage: View {
  var urlString: String

  var body: some View {
    if let image = ImageCache.image(for: urlString) {
      Image(uiImage: image).resizable().scaledToFit()
    } else if let url = ImageCache.absoluteURL(urlString) {
      AsyncImage(url: url) { phase in
        if let image = phase.image {
          image.resizable().scaledToFit()
        } else {
          Color.clear
        }
      }
    }
  }
}

enum ImageCache {
  private static var memory: [String: UIImage] = [:]
  private static let lock = NSLock()

  static func absoluteURL(_ raw: String) -> URL? {
    if raw.hasPrefix("http") { return URL(string: raw) }
    if raw.hasPrefix("/") { return URL(string: raw, relativeTo: BuddyConfig.serverURL)?.absoluteURL }
    return URL(string: raw)
  }

  private static func file(for raw: String) -> URL {
    let safe = Data(raw.utf8).base64EncodedString()
      .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-").prefix(120)
    let directory = SharedStore.containerURL.appendingPathComponent("images", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent(String(safe))
  }

  static func image(for raw: String) -> UIImage? {
    if raw.hasPrefix("data:image"), let comma = raw.firstIndex(of: ","),
       let data = Data(base64Encoded: String(raw[raw.index(after: comma)...])) {
      return UIImage(data: data)
    }
    lock.lock()
    defer { lock.unlock() }
    if let cached = memory[raw] { return cached }
    if let data = try? Data(contentsOf: file(for: raw)), let image = UIImage(data: data) {
      memory[raw] = image
      return image
    }
    return nil
  }

  /// Fetches every image a widget is about to draw, so the timeline entry renders complete.
  static func prefetch(_ raws: [String?]) async {
    await withTaskGroup(of: Void.self) { group in
      for raw in Set(raws.compactMap { $0 }) where !raw.hasPrefix("data:") {
        guard let url = absoluteURL(raw) else { continue }
        group.addTask {
          var request = URLRequest(url: url)
          // Server-rendered images (panel SVGs, pet faces) sit behind the device token.
          if url.host == BuddyConfig.serverURL.host, let token = Session.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
          }
          guard let (data, response) = try? await URLSession.shared.data(for: request),
                (response as? HTTPURLResponse)?.statusCode ?? 200 < 400,
                let image = UIImage(data: data) else { return }
          let thumbnail = image.preparingThumbnail(of: CGSize(width: 300, height: 300)) ?? image
          if let png = thumbnail.pngData() { try? png.write(to: file(for: raw), options: .atomic) }
        }
      }
    }
  }
}

/// A big round button styled the way the list and board buttons are on the site.
struct StyledButtonFace: View {
  var label: String?
  var style: Styled?
  var on: Bool?
  var compact = false

  var body: some View {
    let background = Color(css: style?.background) ?? Color(css: style?.color) ?? (on == true ? Color.green : Color(red: 0.004, green: 0.314, blue: 0.835))
    let foreground = (style?.background != nil ? Color(css: style?.color) : nil) ?? background.contrastingText
    VStack(spacing: 4) {
      if let image = style?.image {
        RemoteImage(urlString: image).frame(width: compact ? 22 : 30, height: compact ? 22 : 30)
      } else if style?.icon != nil || label == nil {
        BuddyIcon(name: style?.icon, fallbackText: label, size: compact ? 18 : 24, color: foreground)
      }
      if let label, !label.isEmpty {
        Text(label)
          .font(.system(size: compact ? 11 : 13, weight: .semibold, design: .rounded))
          .lineLimit(2)
          .minimumScaleFactor(0.6)
          .multilineTextAlignment(.center)
          .foregroundStyle(foreground)
      }
    }
    .padding(6)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(
      RoundedRectangle(cornerRadius: compact ? 12 : 16, style: .continuous)
        .fill(background.gradient),
    )
  }
}
