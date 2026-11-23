import SwiftUI
import WebKit

/// The whole app is the site: one web view, which is the login page until the phone is signed in.
struct RootView: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    WebContainer(webView: model.shell.webView)
      .background(SitePalette.current(scheme).page.ignoresSafeArea())
      .ignoresSafeArea(edges: .bottom)
  }
}

private struct WebContainer: UIViewRepresentable {
  var webView: WKWebView

  func makeUIView(context: Context) -> WKWebView { webView }
  func updateUIView(_ webView: WKWebView, context: Context) {}
}
