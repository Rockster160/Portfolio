import CoreBluetooth
import CoreLocation
import UIKit

/// Reports this phone's battery and charging state, and (as a feature of its own, since it needs
/// the Bluetooth permission) any connected accessory that exposes the standard battery service.
/// Sends on change, not on a timer: level steps, plug in, unplug, Low Power Mode.
final class BatteryMonitor: NSObject {
  static let shared = BatteryMonitor()

  private var observers: [NSObjectProtocol] = []
  private var central: CBCentralManager?
  private var peripherals: [UUID: CBPeripheral] = [:]
  private var lastSent: (level: Int, state: String)?

  func start() {
    guard observers.isEmpty else { return }
    UIDevice.current.isBatteryMonitoringEnabled = true
    let center = NotificationCenter.default
    for name in [UIDevice.batteryLevelDidChangeNotification, UIDevice.batteryStateDidChangeNotification, .NSProcessInfoPowerStateDidChange] {
      observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.report() })
    }
    report(force: true)
  }

  func stop() {
    observers.forEach(NotificationCenter.default.removeObserver)
    observers = []
    UIDevice.current.isBatteryMonitoringEnabled = false
  }

  /// Creating the manager is what asks for the Bluetooth permission, so it only happens once the
  /// accessories feature is switched on.
  func startAccessories() {
    guard central == nil else { return }
    central = CBCentralManager(delegate: self, queue: nil, options: [CBCentralManagerOptionShowPowerAlertKey: false])
  }

  func stopAccessories() {
    peripherals.values.forEach { central?.cancelPeripheralConnection($0) }
    central = nil
    peripherals = [:]
  }

  /// Bluetooth's answer, for switching the feature on: asks once, then reports what iOS decided.
  func requestBluetooth() async -> Bool {
    if CBCentralManager.authorization == .allowedAlways { return true }
    guard CBCentralManager.authorization == .notDetermined else { return false }
    startAccessories()
    for _ in 0..<600 where CBCentralManager.authorization == .notDetermined {
      try? await Task.sleep(nanoseconds: 100_000_000)
    }
    return CBCentralManager.authorization == .allowedAlways
  }

  var stateName: String {
    switch UIDevice.current.batteryState {
    case .charging: return "charging"
    case .full: return "full"
    case .unplugged: return "unplugged"
    default: return "unknown"
    }
  }

  func report(force: Bool = false) {
    let raw = UIDevice.current.batteryLevel
    guard raw >= 0 else { return }
    let level = Int((raw * 100).rounded())
    let state = stateName
    // Level changes in 1% steps; only a whole-percent change or a plug event is worth a send.
    if !force, let lastSent, lastSent.level == level, lastSent.state == state { return }
    lastSent = (level, state)
    send(device: "phone", name: UIDevice.current.name, level: level, state: state, extra: [
      "low_power": .bool(ProcessInfo.processInfo.isLowPowerModeEnabled),
    ])
  }

  private func send(device: String, name: String, level: Int, state: String, extra: [String: JSONValue] = [:]) {
    // On from the first launch, before anyone has signed in; a reading then has nowhere to go.
    guard Session.isSignedIn else { return }
    var data: [String: JSONValue] = [
      "device": .string(device),
      "name": .string(name),
      "level": .number(Double(level)),
      "charging": .bool(state == "charging" || state == "full"),
      "state": .string(state),
    ]
    extra.forEach { data[$0.key] = $0.value }
    Outbox.enqueue(OutboxItem(kind: .trigger, key: "ios_battery", data: .object(data), source: "battery"))
    Task { await Outbox.flush() }
  }
}

extension BatteryMonitor: CBCentralManagerDelegate, CBPeripheralDelegate {
  private static let batteryService = CBUUID(string: "180F")
  private static let batteryLevel = CBUUID(string: "2A19")

  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    guard central.state == .poweredOn else { return }
    for peripheral in central.retrieveConnectedPeripherals(withServices: [Self.batteryService]) {
      peripherals[peripheral.identifier] = peripheral
      peripheral.delegate = self
      central.connect(peripheral)
    }
  }

  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    peripheral.discoverServices([Self.batteryService])
  }

  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    for service in peripheral.services ?? [] where service.uuid == Self.batteryService {
      peripheral.discoverCharacteristics([Self.batteryLevel], for: service)
    }
  }

  func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
    for characteristic in service.characteristics ?? [] where characteristic.uuid == Self.batteryLevel {
      peripheral.readValue(for: characteristic)
      if characteristic.properties.contains(.notify) { peripheral.setNotifyValue(true, for: characteristic) }
    }
  }

  func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
    guard let byte = characteristic.value?.first else { return }
    let name = peripheral.name ?? "Accessory"
    let key = name.lowercased().replacingOccurrences(of: " ", with: "_")
    send(device: key, name: name, level: Int(byte), state: "unknown")
  }
}

/// Location from iOS itself: significant moves, visits (arrived / left), and your saved places as
/// monitored regions. Each lands as an `ios_location` trigger, timestamped when iOS saw it.
// Its state is only touched on the main thread, where the manager calls back.
final class LocationService: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
  static let shared = LocationService()

  let manager = CLLocationManager()
  private var lastSent: CLLocation?
  private var authorizationContinuation: CheckedContinuation<CLAuthorizationStatus, Never>?

  override init() {
    super.init()
    manager.delegate = self
    manager.pausesLocationUpdatesAutomatically = true
    manager.activityType = .other
  }

  /// iOS's first prompt never offers Always Allow. Asking for Always straight after "While Using"
  /// brings up its second one, "Change to Always Allow", and both answers are waited for so the page
  /// shows where it ended up. iOS shows that second prompt once per install and says nothing when it
  /// doesn't, hence the cap on the wait.
  func requestAlways() async -> CLAuthorizationStatus {
    if manager.authorizationStatus == .notDetermined {
      _ = await awaitAuthorization { self.manager.requestWhenInUseAuthorization() }
    }
    if manager.authorizationStatus == .authorizedWhenInUse {
      _ = await awaitAuthorization(timeout: 15) { self.manager.requestAlwaysAuthorization() }
    }
    return manager.authorizationStatus
  }

  private func awaitAuthorization(timeout: TimeInterval? = nil, _ ask: @escaping () -> Void) async -> CLAuthorizationStatus {
    await withCheckedContinuation { continuation in
      authorizationContinuation = continuation
      ask()
      guard let timeout else { return }
      DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
        guard let self, let waiting = self.authorizationContinuation else { return }
        self.authorizationContinuation = nil
        waiting.resume(returning: self.manager.authorizationStatus)
      }
    }
  }

  func start() {
    let preferences = Preferences.current
    manager.allowsBackgroundLocationUpdates = manager.authorizationStatus == .authorizedAlways
    manager.showsBackgroundLocationIndicator = false
    manager.startMonitoringSignificantLocationChanges()
    switch preferences.locationMode {
    case .significant:
      manager.stopUpdatingLocation()
    case .balanced:
      manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
      manager.distanceFilter = max(preferences.locationMinimumMeters, 100)
      manager.startUpdatingLocation()
    case .continuous:
      manager.desiredAccuracy = kCLLocationAccuracyBest
      manager.distanceFilter = max(preferences.locationMinimumMeters / 3, 10)
      manager.startUpdatingLocation()
    }
    if preferences.locationVisits {
      manager.startMonitoringVisits()
    } else {
      manager.stopMonitoringVisits()
    }
    refreshRegions()
  }

  func stop() {
    manager.stopUpdatingLocation()
    manager.stopMonitoringSignificantLocationChanges()
    manager.stopMonitoringVisits()
    manager.monitoredRegions.forEach(manager.stopMonitoring)
  }

  /// Saved places from the server become geofences. iOS allows twenty, so the closest twenty win.
  func refreshRegions() {
    manager.monitoredRegions.forEach(manager.stopMonitoring)
    guard Preferences.current.locationRegions else { return }
    let here = manager.location
    let places = Catalog.cached.places.sorted { first, second in
      guard let here else { return first.name < second.name }
      return here.distance(from: CLLocation(latitude: first.lat, longitude: first.lng)) < here.distance(from: CLLocation(latitude: second.lat, longitude: second.lng))
    }
    for place in places.prefix(20) {
      let region = CLCircularRegion(
        center: CLLocationCoordinate2D(latitude: place.lat, longitude: place.lng),
        radius: min(max(place.radius ?? 150, 100), manager.maximumRegionMonitoringDistance),
        identifier: "place:\(place.id):\(place.name)",
      )
      region.notifyOnEntry = true
      region.notifyOnExit = true
      manager.startMonitoring(for: region)
    }
  }

  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    authorizationContinuation?.resume(returning: manager.authorizationStatus)
    authorizationContinuation = nil
    if Feature.location.isEnabled { start() }
  }

  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    guard let location = locations.last, location.horizontalAccuracy >= 0, location.horizontalAccuracy < 1000 else { return }
    if let lastSent, location.distance(from: lastSent) < Preferences.current.locationMinimumMeters,
       location.timestamp.timeIntervalSince(lastSent.timestamp) < 15 * 60 {
      return
    }
    lastSent = location
    send(kind: "move", location: location, at: location.timestamp)
  }

  func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
    let departed = visit.departureDate != .distantFuture
    let location = CLLocation(latitude: visit.coordinate.latitude, longitude: visit.coordinate.longitude)
    var extra: [String: JSONValue] = ["action": .string(departed ? "departed" : "arrived")]
    if visit.arrivalDate != .distantPast { extra["arrived_at"] = .string(ISO8601.string(visit.arrivalDate)) }
    if departed { extra["departed_at"] = .string(ISO8601.string(visit.departureDate)) }
    send(kind: "visit", location: location, at: departed ? visit.departureDate : visit.arrivalDate, extra: extra, accuracy: visit.horizontalAccuracy)
  }

  func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
    regionEvent(region, action: "arrived")
  }

  func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
    regionEvent(region, action: "departed")
  }

  private func regionEvent(_ region: CLRegion, action: String) {
    guard let circle = region as? CLCircularRegion else { return }
    let parts = region.identifier.split(separator: ":", maxSplits: 2).map(String.init)
    let location = CLLocation(latitude: circle.center.latitude, longitude: circle.center.longitude)
    send(kind: "region", location: manager.location ?? location, at: Date(), extra: [
      "action": .string(action),
      "place": .string(parts.count > 2 ? parts[2] : region.identifier),
      "place_id": .string(parts.count > 1 ? parts[1] : ""),
    ])
  }

  private func send(kind: String, location: CLLocation, at date: Date, extra: [String: JSONValue] = [:], accuracy: Double? = nil) {
    var data: [String: JSONValue] = [
      "kind": .string(kind),
      "lat": .number(location.coordinate.latitude),
      "lng": .number(location.coordinate.longitude),
      "accuracy": .number(accuracy ?? location.horizontalAccuracy),
      "altitude": .number(location.altitude),
      "speed": .number(max(location.speed, 0)),
      "course": .number(location.course),
      "at": .string(ISO8601.string(date)),
    ]
    extra.forEach { data[$0.key] = $0.value }
    var item = OutboxItem(kind: .trigger, key: "ios_location", data: .object(data), source: "location")
    item.pressedAt = date
    Outbox.enqueue(item)
    Task { await Outbox.flush() }
  }
}
