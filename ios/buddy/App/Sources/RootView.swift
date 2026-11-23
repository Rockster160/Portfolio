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
      .overlay(alignment: .top) { LoadingBar(progress: model.progress, color: SitePalette.current(scheme).button) }
  }
}

private struct WebContainer: UIViewRepresentable {
  var webView: WKWebView

  func makeUIView(context: Context) -> WKWebView { webView }
  func updateUIView(_ webView: WKWebView, context: Context) {}
}

/// How far the page being opened has got, so a tap shows straight away that it took, even while
/// the page itself is still on its way.
@MainActor
final class PageProgress: ObservableObject {
  @Published private(set) var value: Double = 0
  @Published private(set) var loading = false
  private var observations: [NSKeyValueObservation] = []

  init(webView: WKWebView) {
    observations = [
      webView.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in
        Task { @MainActor in self?.value = view.estimatedProgress }
      },
      webView.observe(\.isLoading, options: [.new]) { [weak self] view, _ in
        Task { @MainActor in self?.loading = view.isLoading }
      },
    ]
  }
}

private struct LoadingBar: View {
  @ObservedObject var progress: PageProgress
  var color: Color

  var body: some View {
    GeometryReader { geometry in
      Rectangle()
        .fill(color)
        // Never shown empty: the first tenth appears the moment the page starts to open.
        .frame(width: geometry.size.width * max(progress.value, 0.1), height: 3)
        .opacity(progress.loading ? 1 : 0)
        .animation(.easeOut(duration: 0.2), value: progress.value)
        .animation(.easeOut(duration: 0.3), value: progress.loading)
    }
    .frame(height: 3)
    .allowsHitTesting(false)
  }
}
