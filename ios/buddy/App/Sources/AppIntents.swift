import AppIntents
import Foundation

/// "Tell Buddy …" — goes into the primary conversation and waits for the reply, which Siri reads
/// back or Shortcuts shows.
struct TellBuddyIntent: AppIntent {
  static let title: LocalizedStringResource = "Tell Buddy"
  static let description = IntentDescription("Send a message to Buddy in your main conversation and get the reply.")

  @Parameter(title: "Message", requestValueDialog: "What should I tell Buddy?") var message: String
  @Parameter(title: "Wait for the reply", default: true) var wait: Bool

  static var parameterSummary: some ParameterSummary {
    Summary("Tell Buddy \(\.$message)") { \.$wait }
  }

  func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
    guard Session.isSignedIn else { throw IntentFailure.signedOut }
    if !wait {
      Outbox.enqueue(OutboxItem(kind: .buddy, text: message, source: "intent"))
      await Outbox.flush()
      return .result(value: "", dialog: "Sent to Buddy.")
    }
    let reply = try await Outbox.sendInline(kind: .buddy, text: message, source: "intent")
    let text = reply.response ?? "Buddy's still thinking — the reply will land in the conversation."
    return .result(value: text, dialog: IntentDialog(stringLiteral: text))
  }
}

/// Runs a command on the server and shows what it said.
struct RunCommandIntent: AppIntent {
  static let title: LocalizedStringResource = "Run Buddy Command"
  static let description = IntentDescription("Run a command on your server right now and show the response.")

  @Parameter(title: "Command", requestValueDialog: "What's the command?") var command: String

  static var parameterSummary: some ParameterSummary { Summary("Run \(\.$command)") }

  func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
    guard Session.isSignedIn else { throw IntentFailure.signedOut }
    let reply = try await Outbox.sendInline(kind: .command, text: command, source: "intent")
    let text = reply.response ?? "Done."
    return .result(value: text, dialog: IntentDialog(stringLiteral: text))
  }
}

/// The offline-proof version: saved to the phone instantly with the time it was pressed, sent
/// whenever there's a connection. Never fails for lack of signal.
struct QueueCommandIntent: AppIntent {
  static let title: LocalizedStringResource = "Queue Buddy Command"
  static let description = IntentDescription("Save a command now and send it, with the time it was pressed, as soon as there's a connection. Works with no signal.")

  @Parameter(title: "Command") var command: String
  @Parameter(title: "Send to Buddy instead", default: false) var toBuddy: Bool

  static var parameterSummary: some ParameterSummary {
    Summary("Queue \(\.$command)") { \.$toBuddy }
  }

  func perform() async throws -> some IntentResult & ProvidesDialog {
    Outbox.enqueue(OutboxItem(kind: toBuddy ? .buddy : .command, text: command, source: "intent_queue"))
    // Try once now, briefly; a slow or absent network leaves it queued rather than failing.
    await withTaskGroup(of: Void.self) { group in
      group.addTask { await Outbox.flush() }
      group.addTask { try? await Task.sleep(nanoseconds: 4_000_000_000) }
      await group.next()
      group.cancelAll()
    }
    let waiting = Outbox.pendingCount
    return .result(dialog: waiting > 0 ? "Saved. \(waiting) waiting to send." : "Sent.")
  }
}

struct RunTaskIntent: AppIntent {
  static let title: LocalizedStringResource = "Run Jil Task"
  @Parameter(title: "Task") var task: TaskEntity
  @Parameter(title: "Input (JSON or text)") var input: String?

  func perform() async throws -> some IntentResult & ProvidesDialog {
    Outbox.enqueue(OutboxItem(kind: .task, text: task.name, key: task.id, data: input.map(Self.parse), source: "intent"))
    await Outbox.flush()
    return .result(dialog: "Running \(task.name).")
  }

  static func parse(_ raw: String) -> JSONValue {
    if let data = raw.data(using: .utf8), let json = try? JSONDecoder().decode(JSONValue.self, from: data) { return json }
    return .object(["text": .string(raw)])
  }
}

struct RunRoutineIntent: AppIntent {
  static let title: LocalizedStringResource = "Run Buddy Routine"
  @Parameter(title: "Routine") var routine: RoutineEntity

  func perform() async throws -> some IntentResult & ProvidesDialog {
    Outbox.enqueue(OutboxItem(kind: .routine, text: routine.name, key: routine.id, source: "intent"))
    await Outbox.flush()
    return .result(dialog: "Running \(routine.name).")
  }
}

struct FireTriggerIntent: AppIntent {
  static let title: LocalizedStringResource = "Fire Jil Trigger"
  static let description = IntentDescription("Fire a Jil trigger with optional data. Queued, so it works offline.")
  @Parameter(title: "Trigger") var trigger: String
  @Parameter(title: "Data (JSON or text)") var input: String?

  func perform() async throws -> some IntentResult {
    Outbox.enqueue(OutboxItem(kind: .trigger, key: trigger, data: input.map(RunTaskIntent.parse), source: "intent"))
    await Outbox.flush()
    return .result()
  }
}

struct OpenCheckInIntent: AppIntent {
  static let title: LocalizedStringResource = "Open Check-In"
  static let openAppWhenRun = true

  @MainActor
  func perform() async throws -> some IntentResult {
    await AppModel.shared.openCheckIn(id: nil)
    return .result()
  }
}

struct OpenBuddyScreenIntent: AppIntent {
  static let title: LocalizedStringResource = "Open in Buddy"
  static let openAppWhenRun = true
  @Parameter(title: "Path", default: "/agenda") var path: String

  @MainActor
  func perform() async throws -> some IntentResult {
    AppModel.shared.route = .web(path: path)
    return .result()
  }
}

/// A hot link from Shortcuts or Siri. One that asks a question asks it right there, so it never
/// has to open the app.
struct RunHotLinkIntent: AppIntent {
  static let title: LocalizedStringResource = "Run Hot Link"
  @Parameter(title: "Hot link") var link: HotLinkEntity
  @Parameter(title: "Answer") var answer: String?

  func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog & OpensIntent {
    guard let hotLink = link.link else { return .result(value: "", dialog: "") }
    var action = hotLink.action
    if action.kind == .prompt {
      guard let answer, !answer.isEmpty else {
        throw $answer.needsValueError(IntentDialog(stringLiteral: action.placeholder ?? hotLink.title))
      }
      action = ButtonAction(kind: action.sendAs ?? .buddy, prefix: action.prefix, data: action.data, inline: action.inline)
      let reply = try await AskAndSendIntent.send(action, answer: answer)
      return .result(value: reply, dialog: IntentDialog(stringLiteral: reply))
    }
    if case .open(let url) = await ActionRunner.run(action, source: "intent") {
      return .result(value: "", opensIntent: OpenURLIntent(url), dialog: "")
    }
    return .result(value: "", dialog: "")
  }
}

/// Asks the question given when it runs, then sends the answer (after the prefix) as a command or
/// a Buddy message.
struct AskAndSendIntent: AppIntent {
  static let title: LocalizedStringResource = "Ask and Send to Buddy"

  @Parameter(title: "Question") var question: String
  @Parameter(title: "Prefix") var prefix: String?
  @Parameter(title: "Send to", default: .buddy) var target: SendTarget
  @Parameter(title: "Show the reply", default: true) var wait: Bool
  @Parameter(title: "Answer") var answer: String?

  static var parameterSummary: some ParameterSummary {
    Summary("Ask \(\.$question) and send to \(\.$target)") {
      \.$prefix
      \.$wait
      \.$answer
    }
  }

  func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
    guard let answer, !answer.isEmpty else { throw $answer.needsValueError(IntentDialog(stringLiteral: question)) }
    let action = ButtonAction(kind: target == .command ? .command : .buddy, prefix: prefix, inline: wait)
    let reply = try await Self.send(action, answer: answer)
    return .result(value: reply, dialog: IntentDialog(stringLiteral: reply))
  }

  /// The reply when one was waited for, otherwise whether it went or is queued.
  static func send(_ action: ButtonAction, answer: String) async throws -> String {
    guard Session.isSignedIn else { throw IntentFailure.signedOut }
    switch await ActionRunner.run(action, typed: answer, source: "intent") {
    case .replied(let reply):
      return reply
    case .queued, .open:
      return Outbox.pendingCount > 0 ? "Queued." : "Sent."
    }
  }
}

enum SendTarget: String, AppEnum {
  case buddy
  case command

  static let typeDisplayRepresentation: TypeDisplayRepresentation = "Send to"
  static let caseDisplayRepresentations: [SendTarget: DisplayRepresentation] = [
    .buddy: "Buddy",
    .command: "Command",
  ]
}

enum IntentFailure: Error, CustomLocalizedStringResourceConvertible {
  case signedOut

  var localizedStringResource: LocalizedStringResource {
    switch self {
    case .signedOut: return "Open Buddy and sign in first."
    }
  }
}

struct BuddyShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: TellBuddyIntent(),
      phrases: [
        "Tell \(.applicationName) something",
        "Message \(.applicationName)",
        "Ask \(.applicationName)",
      ],
      shortTitle: "Tell Buddy",
      systemImageName: "bubble.left.and.text.bubble.right.fill",
    )
    AppShortcut(
      intent: QueueCommandIntent(),
      phrases: ["Queue a \(.applicationName) command", "Log with \(.applicationName)"],
      shortTitle: "Queue Command",
      systemImageName: "tray.and.arrow.up.fill",
    )
    AppShortcut(
      intent: AskAndSendIntent(),
      phrases: ["Ask and send with \(.applicationName)"],
      shortTitle: "Ask and Send",
      systemImageName: "questionmark.bubble.fill",
    )
    AppShortcut(
      intent: RunCommandIntent(),
      phrases: ["Run a \(.applicationName) command"],
      shortTitle: "Run Command",
      systemImageName: "bolt.fill",
    )
    AppShortcut(
      intent: OpenCheckInIntent(),
      phrases: ["Check in with \(.applicationName)", "Open \(.applicationName) check-in"],
      shortTitle: "Check In",
      systemImageName: "face.smiling",
    )
    AppShortcut(
      intent: RunHotLinkIntent(),
      phrases: ["Run \(\.$link) in \(.applicationName)", "\(.applicationName) \(\.$link)"],
      shortTitle: "Hot Link",
      systemImageName: "square.grid.2x2.fill",
    )
    AppShortcut(
      intent: RunTaskIntent(),
      phrases: ["Run a Jil task with \(.applicationName)"],
      shortTitle: "Run Task",
      systemImageName: "point.3.connected.trianglepath.dotted",
    )
    AppShortcut(
      intent: RunRoutineIntent(),
      phrases: ["Run \(\.$routine) with \(.applicationName)", "Start a \(.applicationName) routine"],
      shortTitle: "Run Routine",
      systemImageName: "list.bullet.rectangle.fill",
    )
  }
}
