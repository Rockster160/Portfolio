import SwiftUI
import UIKit

/// A page's own confirm(), drawn as the site's modal (`.modal-content.app-card-container`) over
/// the page, since a script waiting on confirm() can't draw anything itself.
enum SiteDialog {
  @MainActor
  static func confirm(_ message: String) async -> Bool {
    guard let top = topController() else { return false }
    return await withCheckedContinuation { continuation in
      var host: UIViewController?
      let card = ConfirmCard(message: message) { answer in
        host?.dismiss(animated: true)
        continuation.resume(returning: answer)
      }
      let controller = UIHostingController(rootView: card)
      controller.modalPresentationStyle = .overFullScreen
      controller.modalTransitionStyle = .crossDissolve
      controller.view.backgroundColor = .clear
      host = controller
      top.present(controller, animated: true)
    }
  }

  @MainActor
  private static func topController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    var top = scenes.compactMap { $0.keyWindow?.rootViewController }.first
    while let presented = top?.presentedViewController { top = presented }
    return top
  }
}

private struct ConfirmCard: View {
  var message: String
  var answer: (Bool) -> Void
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    let palette = SitePalette.current(scheme)
    ZStack {
      Color.black.opacity(0.4).ignoresSafeArea().onTapGesture { answer(false) }
      VStack(alignment: .leading, spacing: 0) {
        Text("Are you sure?")
          .font(SiteFont.arial(32))
          .foregroundStyle(.white)
          .padding(20)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(palette.cardTitle)
        VStack(spacing: 15) {
          Text(message)
            .font(SiteFont.arial(16))
            .foregroundStyle(palette.text)
            .frame(maxWidth: .infinity, alignment: .leading)
          HStack(spacing: 8) {
            button("Cancel", palette) { answer(false) }
            button("OK", palette) { answer(true) }
          }
        }
        .padding(15)
      }
      .background(palette.card)
      .clipShape(RoundedRectangle(cornerRadius: 10))
      .shadow(color: palette.cardShadow, radius: 5, x: 3, y: 3)
      .frame(maxWidth: 500)
      .padding(10)
    }
  }

  private func button(_ title: String, _ palette: SitePalette, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(title)
        .font(SiteFont.arial(15, bold: true))
        .foregroundStyle(palette.buttonText)
        .padding(.vertical, 6)
        .padding(.horizontal, 24)
        .background(palette.button, in: RoundedRectangle(cornerRadius: 6))
        .shadow(color: palette.buttonEdge, radius: 0, x: 0, y: 1)
    }
    .buttonStyle(.plain)
  }
}
