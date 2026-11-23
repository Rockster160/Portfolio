import Contacts
import EventKit
import Foundation

/// Keeps calendars, reminders and contacts in step with the server by diffing against what was
/// last sent. Each run sends only what changed since the last one, so a missed run is caught up
/// by the next, and an unchanged store sends nothing.
final class NativeSync {
  static let shared = NativeSync()

  let events = EKEventStore()
  let contacts = CNContactStore()
  private var observers: [NSObjectProtocol] = []

  /// What was last sent, per kind: item id → fingerprint.
  private func sent(_ kind: String) -> [String: String] {
    SharedStore.readFile([String: String].self, name: "sync-\(kind).json") ?? [:]
  }

  private func saveSent(_ kind: String, _ value: [String: String]) {
    SharedStore.mutateFile([String: String].self, name: "sync-\(kind).json", empty: [:]) { $0 = value }
  }

  func startObserving() {
    guard observers.isEmpty else { return }
    let center = NotificationCenter.default
    observers.append(center.addObserver(forName: .EKEventStoreChanged, object: events, queue: .main) { [weak self] _ in
      Task {
        await self?.syncCalendar()
        await self?.syncReminders()
      }
    })
    observers.append(center.addObserver(forName: .CNContactStoreDidChange, object: nil, queue: .main) { [weak self] _ in
      Task { await self?.syncContacts() }
    })
  }

  func requestCalendar() async -> Bool { (try? await events.requestFullAccessToEvents()) ?? false }
  func requestReminders() async -> Bool { (try? await events.requestFullAccessToReminders()) ?? false }
  func requestContacts() async -> Bool { (try? await contacts.requestAccess(for: .contacts)) ?? false }

  func reset(_ kind: String) {
    saveSent(kind, [:])
  }

  // MARK: Calendar

  func syncCalendar() async {
    guard Feature.calendar.isEnabled, EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return }
    let preferences = Preferences.current
    let start = Calendar.current.date(byAdding: .day, value: -preferences.calendarDaysBack, to: Date()) ?? Date()
    let end = Calendar.current.date(byAdding: .day, value: preferences.calendarDaysAhead, to: Date()) ?? Date()
    var calendars = events.calendars(for: .event)
    if !preferences.calendarIdentifiers.isEmpty {
      calendars = calendars.filter { preferences.calendarIdentifiers.contains($0.calendarIdentifier) }
    }
    let predicate = events.predicateForEvents(withStart: start, end: end, calendars: calendars)
    var current: [String: [String: JSONValue]] = [:]
    for event in events.events(matching: predicate) {
      let id = "\(event.calendarItemExternalIdentifier ?? event.eventIdentifier ?? UUID().uuidString)@\(Int(event.startDate.timeIntervalSince1970))"
      current[id] = [
        "id": .string(id),
        "title": .string(event.title ?? ""),
        "starts_at": .string(ISO8601.string(event.startDate)),
        "ends_at": .string(ISO8601.string(event.endDate)),
        "all_day": .bool(event.isAllDay),
        "location": JSONValue(event.location),
        "notes": JSONValue(event.notes.map { String($0.prefix(2000)) }),
        "calendar": .string(event.calendar.title),
        "calendar_color": JSONValue(event.calendar.cgColor.flatMap(Self.hex)),
        "url": JSONValue(event.url?.absoluteString),
        "status": .string(Self.status(event.status)),
        "attendees": .number(Double(event.attendees?.count ?? 0)),
      ]
    }
    // Events that ended before the window are out of range, not deleted; forget them quietly.
    let windowStart = start.timeIntervalSince1970
    await send(kind: "calendar", key: "ios_calendar", field: "event", current: current) { id in
      guard let epoch = id.split(separator: "@").last.flatMap({ Double($0) }) else { return true }
      return epoch >= windowStart
    }
  }

  private static func status(_ status: EKEventStatus) -> String {
    switch status {
    case .confirmed: return "confirmed"
    case .tentative: return "tentative"
    case .canceled: return "canceled"
    default: return "none"
    }
  }

  private static func hex(_ color: CGColor) -> String? {
    guard let components = color.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components, components.count >= 3 else { return nil }
    return String(format: "#%02x%02x%02x", Int(components[0] * 255), Int(components[1] * 255), Int(components[2] * 255))
  }

  // MARK: Reminders

  func syncReminders() async {
    guard Feature.reminders.isEnabled, EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else { return }
    let preferences = Preferences.current
    var calendars = events.calendars(for: .reminder)
    if !preferences.reminderListIdentifiers.isEmpty {
      calendars = calendars.filter { preferences.reminderListIdentifiers.contains($0.calendarIdentifier) }
    }
    let predicate = preferences.remindersIncludeCompleted
      ? events.predicateForReminders(in: calendars)
      : events.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: calendars)
    let reminders: [EKReminder] = await withCheckedContinuation { continuation in
      events.fetchReminders(matching: predicate) { continuation.resume(returning: $0 ?? []) }
    }
    var current: [String: [String: JSONValue]] = [:]
    for reminder in reminders {
      let id = reminder.calendarItemExternalIdentifier ?? reminder.calendarItemIdentifier
      let due = reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) }
      current[id] = [
        "id": .string(id),
        "title": .string(reminder.title ?? ""),
        "list": .string(reminder.calendar.title),
        "due_at": JSONValue(due.map(ISO8601.string)),
        "notes": JSONValue(reminder.notes),
        "priority": .number(Double(reminder.priority)),
        "completed": .bool(reminder.isCompleted),
        "completed_at": JSONValue(reminder.completionDate.map(ISO8601.string)),
        "url": JSONValue(reminder.url?.absoluteString),
      ]
    }
    let previous = sent("reminders")
    // A reminder that vanished from the incomplete-only fetch was most likely completed.
    await send(kind: "reminders", key: "ios_reminders", field: "reminder", current: current, removedAction: preferences.remindersIncludeCompleted ? "removed" : "completed") { previous[$0] != nil }
  }

  // MARK: Contacts

  func syncContacts() async {
    guard Feature.contacts.isEnabled, CNContactStore.authorizationStatus(for: .contacts) == .authorized else { return }
    let keys: [CNKeyDescriptor] = [
      CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey, CNContactMiddleNameKey,
      CNContactOrganizationNameKey, CNContactPhoneNumbersKey, CNContactEmailAddressesKey,
      CNContactPostalAddressesKey, CNContactBirthdayKey, CNContactUrlAddressesKey,
      CNContactRelationsKey, CNContactJobTitleKey,
    ] as [CNKeyDescriptor]
    let request = CNContactFetchRequest(keysToFetch: keys)
    var current: [String: [String: JSONValue]] = [:]
    let store = contacts
    await Task.detached {
      try? store.enumerateContacts(with: request) { contact, _ in
        let addresses: [JSONValue] = contact.postalAddresses.map { labeled in
          let address = labeled.value
          return .object([
            "label": .string(CNLabeledValue<NSString>.localizedString(forLabel: labeled.label ?? "")),
            "street": .string(CNPostalAddressFormatter.string(from: address, style: .mailingAddress).replacingOccurrences(of: "\n", with: ", ")),
            "city": .string(address.city),
            "state": .string(address.state),
            "postal_code": .string(address.postalCode),
            "country": .string(address.country),
          ])
        }
        var birthday: JSONValue = .null
        if let components = contact.birthday {
          birthday = .object([
            "day": JSONValue(components.day),
            "month": JSONValue(components.month),
            "year": JSONValue(components.year == NSDateComponentUndefined ? nil : components.year),
          ])
        }
        current[contact.identifier] = [
          "id": .string(contact.identifier),
          "name": .string(contact.givenName),
          "last_name": .string(contact.familyName),
          "nickname": .string(contact.nickname),
          "organization": .string(contact.organizationName),
          "job_title": .string(contact.jobTitle),
          "phones": .array(contact.phoneNumbers.map { .object(["label": .string(CNLabeledValue<NSString>.localizedString(forLabel: $0.label ?? "")), "value": .string($0.value.stringValue)]) }),
          "emails": .array(contact.emailAddresses.map { .object(["label": .string(CNLabeledValue<NSString>.localizedString(forLabel: $0.label ?? "")), "value": .string($0.value as String)]) }),
          "addresses": .array(addresses),
          "urls": .array(contact.urlAddresses.map { .string($0.value as String) }),
          "relations": .array(contact.contactRelations.map { .object(["label": .string(CNLabeledValue<NSString>.localizedString(forLabel: $0.label ?? "")), "name": .string($0.value.name)]) }),
          "birthday": birthday,
        ]
      }
    }.value
    await send(kind: "contacts", key: "ios_contacts", field: "contact", current: current, addedAction: "added", changedAction: "updated")
  }

  // MARK: Diff and send

  /// Compares against the last-sent fingerprints and queues the differences in batches of 25.
  private func send(
    kind: String,
    key: String,
    field: String,
    current: [String: [String: JSONValue]],
    addedAction: String = "added",
    changedAction: String = "changed",
    removedAction: String = "removed",
    shouldReportRemoval: (String) -> Bool = { _ in true },
  ) async {
    let previous = sent(kind)
    var next: [String: String] = [:]
    var changes: [JSONValue] = []
    for (id, value) in current {
      let fingerprint = Self.fingerprint(value)
      next[id] = fingerprint
      if let old = previous[id] {
        if old != fingerprint {
          changes.append(.object(["action": .string(changedAction), field: .object(value)]))
        }
      } else {
        changes.append(.object(["action": .string(addedAction), field: .object(value)]))
      }
    }
    for id in previous.keys where current[id] == nil && shouldReportRemoval(id) {
      changes.append(.object(["action": .string(removedAction), field: .object(["id": .string(id)])]))
    }
    guard !changes.isEmpty else { return }
    for start in stride(from: 0, to: changes.count, by: 25) {
      let batch = Array(changes[start..<min(start + 25, changes.count)])
      Outbox.enqueue(OutboxItem(kind: .trigger, key: key, data: .object(["action": .string("batch"), "changes": .array(batch)]), source: "sync_\(kind)"))
    }
    // The outbox now owns delivery, so the snapshot moves on; a failed send retries from the queue.
    saveSent(kind, next)
    ActivityLog.add("\(kind.capitalized): \(changes.count) change\(changes.count == 1 ? "" : "s") queued")
    await Outbox.flush()
  }

  private static func fingerprint(_ value: [String: JSONValue]) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let data = (try? encoder.encode(value)) ?? Data()
    var hash: UInt64 = 14695981039346656037
    for byte in data {
      hash ^= UInt64(byte)
      hash = hash &* 1099511628211
    }
    return String(hash, radix: 36)
  }
}
