import AppIntents
import SwiftUI
import WidgetKit

@main
struct BuddyWidgetBundle: WidgetBundle {
  var body: some Widget {
    // The order the widget gallery lists them in.
    HotLinksWidget()
    ListWidget()
    AgendaWidget()
    ButtonsWidget()
    BoardWidget()
    PanelWidget()
    TimerLiveActivity()
    HotLinkControl()
    CommandControl()
  }
}

/// Lets the server reload widgets the moment their data changes, instead of each widget waiting
/// for its next timeline refresh. The token goes to the server on the device record.
struct BuddyWidgetPushHandler: WidgetPushHandler {
  init() {}

  func pushTokenDidChange(_ pushInfo: WidgetPushInfo, widgets: [WidgetInfo]) {
    let token = pushInfo.token.map { String(format: "%02x", $0) }.joined()
    SharedStore.defaults.set(token, forKey: "widget_push_token")
    Task {
      _ = try? await APIClient.shared.patch("api/ios/device", body: ["widget_push_token": token], as: JSONValue.self)
    }
  }
}

// MARK: - Control Center / Lock Screen / Action button

struct RunHotLinkControlIntent: ControlConfigurationIntent {
  static let title: LocalizedStringResource = "Hot Link"
  @Parameter(title: "Hot link") var link: HotLinkEntity?
}

/// Runs a hot link from Control Center, the Lock Screen or the Action button.
struct PerformHotLinkIntent: AppIntent {
  static let title: LocalizedStringResource = "Run Hot Link"
  static let isDiscoverable = false

  @Parameter(title: "Hot link") var link: HotLinkEntity?
  @Parameter(title: "Answer") var answer: String?

  init() {}
  init(link: HotLinkEntity?) { self.link = link }

  func perform() async throws -> some IntentResult & OpensIntent {
    guard let hotLink = link?.link else { return .result() }
    if hotLink.action.kind == .prompt {
      let fallback = await AskIntent.ask(hotLink.pressed, source: "control", answer: $answer)
      return fallback.map { .result(opensIntent: OpenURLIntent($0)) } ?? .result()
    }
    switch await ActionRunner.run(hotLink.action, source: "control") {
    case .open(let url):
      return .result(opensIntent: OpenURLIntent(url))
    case .replied(let reply):
      await ActionRunner.notify(reply, title: hotLink.title)
      return .result()
    case .queued:
      return .result()
    }
  }
}

struct HotLinkControl: ControlWidget {
  var body: some ControlWidgetConfiguration {
    AppIntentControlConfiguration(kind: "BuddyHotLinkControl", intent: RunHotLinkControlIntent.self) { configuration in
      ControlWidgetButton(action: PerformHotLinkIntent(link: configuration.link)) {
        Label(configuration.link?.title ?? "Hot Link", systemImage: configuration.link?.icon ?? "bolt.fill")
      }
    }
    .displayName("Buddy Hot Link")
    .description("Run one of your hot links.")
  }
}

/// "Tell Buddy" from Control Center, the Lock Screen or the Action button, asked in place.
struct CommandControl: ControlWidget {
  static let tell = ButtonAction(kind: .prompt, sendAs: .buddy, placeholder: "Tell Buddy", inline: true)

  var body: some ControlWidgetConfiguration {
    StaticControlConfiguration(kind: "BuddyComposeControl") {
      ControlWidgetButton(action: AskIntent(Self.tell, source: "control")) {
        Label("Tell Buddy", systemImage: "bubble.left.and.text.bubble.right.fill")
      }
    }
    .displayName("Tell Buddy")
    .description("Type a command or a message to Buddy.")
  }
}
