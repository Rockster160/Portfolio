import SwiftUI
import UIKit

/// The site's palette (config/_variables.scss and components/forms.scss) for what can't be a web
/// page: widgets, Live Activities and controls. Every screen in the app itself is the site.
struct SitePalette {
  var page: Color
  var card: Color
  var cardTitle: Color
  var cardShadow: Color
  var label: Color
  var text: Color
  var inputBackground: Color
  var inputBorder: Color
  var placeholder: Color
  var button: Color
  var buttonPressed: Color
  var buttonEdge: Color
  var buttonText: Color
  var buttonTextShadow: Color
  var disabled: Color
  var danger: Color

  /// The site's `dark-mode` follows the account, so this does too once the server has said which
  /// it is; until then the phone's appearance decides.
  static func current(_ scheme: ColorScheme) -> SitePalette {
    let stored = SharedStore.defaults.object(forKey: SharedStore.Key.darkMode) as? Bool
    return (stored ?? (scheme == .dark)) ? dark : light
  }

  static let light = SitePalette(
    page: hex(0xF3F7FF),
    card: hex(0xD5E5FF),
    cardTitle: hex(0x0160FF),
    cardShadow: hex(0x6481A1),
    label: hex(0x465B73),
    text: hex(0x3C4F63),
    inputBackground: .white,
    inputBorder: hex(0x6481A1).opacity(0.5),
    placeholder: Color(uiColor: .placeholderText),
    button: hex(0x0160FF),
    buttonPressed: hex(0x003A9A),
    buttonEdge: hex(0x4E90FF),
    buttonText: .white,
    buttonTextShadow: hex(0x0043B3),
    disabled: hex(0x3C4F63),
    danger: hex(0xF6433D),
  )

  static let dark = SitePalette(
    page: hex(0x00102B),
    card: hex(0x0140AA),
    cardTitle: hex(0x013080),
    cardShadow: hex(0x34495E),
    label: hex(0xECF0F1),
    text: hex(0xECF0F1),
    inputBackground: hex(0x6481A1),
    inputBorder: hex(0x0140AA).opacity(0.5),
    placeholder: hex(0x94AAB0),
    button: hex(0x0150D5),
    buttonPressed: hex(0x012A6F),
    buttonEdge: hex(0x2576FE),
    buttonText: hex(0xECF0F1),
    buttonTextShadow: hex(0x013389),
    disabled: hex(0x3C4F63),
    danger: hex(0xF6433D),
  )

  private static func hex(_ value: UInt32) -> Color {
    Color(
      .sRGB,
      red: Double((value >> 16) & 0xFF) / 255,
      green: Double((value >> 8) & 0xFF) / 255,
      blue: Double(value & 0xFF) / 255,
    )
  }
}

enum SiteFont {
  static func arial(_ size: CGFloat, bold: Bool = false) -> Font {
    .custom(bold ? "Arial-BoldMT" : "ArialMT", size: size)
  }
}
