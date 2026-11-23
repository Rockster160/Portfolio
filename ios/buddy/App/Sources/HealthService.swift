import HealthKit

/// Workouts from Apple Health, sent as they're saved — from the Watch, the Fitness app or any app
/// that writes workouts — with the type, duration, calories, distance and heart rate.
final class HealthService {
  static let shared = HealthService()

  let store = HKHealthStore()
  private var observer: HKObserverQuery?
  private let anchorKey = "health_workout_anchor"

  private var readTypes: Set<HKObjectType> {
    var types: Set<HKObjectType> = [
      HKObjectType.workoutType(),
      HKQuantityType(.heartRate),
      HKQuantityType(.activeEnergyBurned),
      HKQuantityType(.distanceWalkingRunning),
      HKQuantityType(.distanceCycling),
      HKQuantityType(.distanceSwimming),
      HKQuantityType(.stepCount),
      HKQuantityType(.appleExerciseTime),
    ]
    types.insert(HKCategoryType(.sleepAnalysis))
    return types
  }

  var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

  func requestAuthorization() async -> Bool {
    guard isAvailable else { return false }
    do {
      try await store.requestAuthorization(toShare: [], read: readTypes)
      return true
    } catch {
      ActivityLog.add("Health authorization failed: \(error.localizedDescription)")
      return false
    }
  }

  /// Apple Health never says whether reading was allowed, only whether it has been asked, so once
  /// it has been asked it counts as allowed; anything refused simply never arrives.
  func authorizationState() async -> PermissionState {
    guard isAvailable else { return .denied }
    let status = try? await store.statusForAuthorizationRequest(toShare: [], read: readTypes)
    return status == .unnecessary ? .granted : .undetermined
  }

  /// Background delivery wakes the app when a workout is saved, even if it hasn't run in days.
  func start() {
    guard isAvailable, observer == nil else { return }
    let query = HKObserverQuery(sampleType: .workoutType(), predicate: nil) { [weak self] _, completion, error in
      guard error == nil, let self else {
        completion()
        return
      }
      Task {
        await self.sendNewWorkouts()
        completion()
      }
    }
    observer = query
    store.execute(query)
    store.enableBackgroundDelivery(for: .workoutType(), frequency: .immediate) { _, error in
      if let error { ActivityLog.add("Workout background delivery: \(error.localizedDescription)") }
    }
  }

  func stop() {
    if let observer { store.stop(observer) }
    observer = nil
    store.disableAllBackgroundDelivery { _, _ in }
  }

  /// Only workouts after the saved anchor; the first run starts from the last two days so turning
  /// this on doesn't replay years of history into the event log.
  func sendNewWorkouts() async {
    let anchor = SharedStore.defaults.data(forKey: anchorKey).flatMap {
      try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: $0)
    }
    let predicate = anchor == nil ? HKQuery.predicateForSamples(withStart: Date().addingTimeInterval(-2 * 86400), end: nil) : nil
    let descriptor = HKAnchoredObjectQueryDescriptor(
      predicates: [.workout(predicate)],
      anchor: anchor,
    )
    guard let result = try? await descriptor.result(for: store) else { return }
    for workout in result.addedSamples {
      await send(workout)
    }
    if let data = try? NSKeyedArchiver.archivedData(withRootObject: result.newAnchor, requiringSecureCoding: true) {
      SharedStore.defaults.set(data, forKey: anchorKey)
    }
    if !result.addedSamples.isEmpty { await Outbox.flush() }
  }

  private func send(_ workout: HKWorkout) async {
    let calories = workout.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()?.doubleValue(for: .kilocalorie())
    let distanceType: HKQuantityType = {
      switch workout.workoutActivityType {
      case .cycling: return HKQuantityType(.distanceCycling)
      case .swimming: return HKQuantityType(.distanceSwimming)
      default: return HKQuantityType(.distanceWalkingRunning)
      }
    }()
    let miles = workout.statistics(for: distanceType)?.sumQuantity()?.doubleValue(for: .mile())
    let heartRate = workout.statistics(for: HKQuantityType(.heartRate))
    let bpm = HKUnit.count().unitDivided(by: .minute())
    var data: [String: JSONValue] = [
      "uuid": .string(workout.uuid.uuidString),
      "type": .string(Self.slug(workout.workoutActivityType)),
      "name": .string(Self.name(workout.workoutActivityType)),
      "started_at": .string(ISO8601.string(workout.startDate)),
      "ended_at": .string(ISO8601.string(workout.endDate)),
      "duration_minutes": .number((workout.duration / 60 * 10).rounded() / 10),
      "source": .string(workout.sourceRevision.source.name),
      "indoor": JSONValue(workout.metadata?[HKMetadataKeyIndoorWorkout] as? Bool),
    ]
    if let calories { data["calories"] = .number(calories.rounded()) }
    if let miles, miles > 0 { data["distance_miles"] = .number((miles * 100).rounded() / 100) }
    if let average = heartRate?.averageQuantity()?.doubleValue(for: bpm) { data["avg_heart_rate"] = .number(average.rounded()) }
    if let maximum = heartRate?.maximumQuantity()?.doubleValue(for: bpm) { data["max_heart_rate"] = .number(maximum.rounded()) }
    var item = OutboxItem(kind: .trigger, key: "ios_workout", data: .object(data), source: "health")
    item.pressedAt = workout.endDate
    Outbox.enqueue(item)
  }

  /// Yesterday's totals, once a day, for anyone who wants steps or sleep in Jil.
  func sendDailyTotals() async {
    guard Preferences.current.healthDailyTotals else { return }
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: Date())
    guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today) else { return }
    let key = "health_daily_sent"
    if SharedStore.defaults.string(forKey: key) == ISO8601.string(yesterday) { return }
    let predicate = HKQuery.predicateForSamples(withStart: yesterday, end: today)
    async let steps = sum(.stepCount, unit: .count(), predicate: predicate)
    async let energy = sum(.activeEnergyBurned, unit: .kilocalorie(), predicate: predicate)
    async let exercise = sum(.appleExerciseTime, unit: .minute(), predicate: predicate)
    let data: [String: JSONValue] = [
      "kind": .string("daily"),
      "date": .string(String(ISO8601.string(yesterday).prefix(10))),
      "steps": JSONValue(await steps),
      "active_calories": JSONValue(await energy),
      "exercise_minutes": JSONValue(await exercise),
      "sleep_hours": JSONValue(await sleepHours(endingOn: today)),
    ]
    var item = OutboxItem(kind: .trigger, key: "ios_health", data: .object(data), source: "health")
    item.pressedAt = today
    Outbox.enqueue(item)
    SharedStore.defaults.set(ISO8601.string(yesterday), forKey: key)
  }

  private func sum(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit, predicate: NSPredicate) async -> Double? {
    let descriptor = HKStatisticsQueryDescriptor(
      predicate: .quantitySample(type: HKQuantityType(identifier), predicate: predicate),
      options: .cumulativeSum,
    )
    return try? await descriptor.result(for: store)?.sumQuantity()?.doubleValue(for: unit).rounded()
  }

  private func sleepHours(endingOn day: Date) async -> Double? {
    let start = day.addingTimeInterval(-12 * 3600)
    let end = day.addingTimeInterval(14 * 3600)
    let descriptor = HKSampleQueryDescriptor(
      predicates: [.categorySample(type: HKCategoryType(.sleepAnalysis), predicate: HKQuery.predicateForSamples(withStart: start, end: end))],
      sortDescriptors: [],
    )
    guard let samples = try? await descriptor.result(for: store) else { return nil }
    let asleep = samples.filter { HKCategoryValueSleepAnalysis.allAsleepValues.map(\.rawValue).contains($0.value) }
    let seconds = asleep.reduce(0) { $0 + $1.endDate.timeIntervalSince($1.startDate) }
    return seconds > 0 ? (seconds / 360).rounded() / 10 : nil
  }

  static func slug(_ type: HKWorkoutActivityType) -> String {
    name(type).lowercased().replacingOccurrences(of: " ", with: "_")
  }

  static func name(_ type: HKWorkoutActivityType) -> String {
    switch type {
    case .running: return "Running"
    case .walking: return "Walking"
    case .cycling: return "Cycling"
    case .swimming: return "Swimming"
    case .hiking: return "Hiking"
    case .yoga: return "Yoga"
    case .traditionalStrengthTraining: return "Strength Training"
    case .functionalStrengthTraining: return "Functional Strength"
    case .highIntensityIntervalTraining: return "HIIT"
    case .elliptical: return "Elliptical"
    case .rowing: return "Rowing"
    case .stairClimbing: return "Stair Climbing"
    case .coreTraining: return "Core Training"
    case .pilates: return "Pilates"
    case .dance: return "Dance"
    case .cooldown: return "Cooldown"
    case .mixedCardio: return "Mixed Cardio"
    case .crossTraining: return "Cross Training"
    case .tennis: return "Tennis"
    case .pickleball: return "Pickleball"
    case .basketball: return "Basketball"
    case .soccer: return "Soccer"
    case .golf: return "Golf"
    case .snowSports: return "Snow Sports"
    case .downhillSkiing: return "Downhill Skiing"
    case .snowboarding: return "Snowboarding"
    case .climbing: return "Climbing"
    case .kickboxing: return "Kickboxing"
    case .boxing: return "Boxing"
    case .martialArts: return "Martial Arts"
    case .flexibility: return "Flexibility"
    case .mindAndBody: return "Mind and Body"
    case .paddleSports: return "Paddle Sports"
    case .waterFitness: return "Water Fitness"
    case .jumpRope: return "Jump Rope"
    case .stepTraining: return "Step Training"
    case .handCycling: return "Hand Cycling"
    case .wheelchairRunPace: return "Wheelchair Run"
    case .wheelchairWalkPace: return "Wheelchair Walk"
    default: return "Workout"
    }
  }
}
