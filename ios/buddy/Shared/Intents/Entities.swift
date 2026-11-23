import AppIntents
import Foundation

/// Pickers read the cached catalog first so a widget's edit sheet opens instantly and offline,
/// and refresh it when they can.
func freshCatalog() async -> Catalog {
  if let fresh = try? await Catalog.refresh() { return fresh }
  return Catalog.cached
}

struct ListEntity: AppEntity {
  static let typeDisplayRepresentation: TypeDisplayRepresentation = "List"
  static let defaultQuery = ListQuery()
  var id: String
  var name: String
  var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

  init(_ item: Catalog.Item) {
    id = item.id
    name = item.name
  }

  init(id: String) {
    self.id = id
    name = "List \(id)"
  }
}

struct ListQuery: EntityQuery {
  func entities(for identifiers: [String]) async throws -> [ListEntity] {
    let items = Catalog.cached.lists
    return identifiers.map { id in items.first { $0.id == id }.map(ListEntity.init) ?? ListEntity(id: id) }
  }

  func suggestedEntities() async throws -> [ListEntity] {
    await freshCatalog().lists.map(ListEntity.init)
  }
}

struct TaskEntity: AppEntity {
  static let typeDisplayRepresentation: TypeDisplayRepresentation = "Jil Task"
  static let defaultQuery = TaskQuery()
  var id: String
  var name: String
  var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

  init(_ item: Catalog.Item) {
    id = item.id
    name = item.name
  }

  init(id: String) {
    self.id = id
    name = "Jil Task \(id)"
  }
}

struct TaskQuery: EntityQuery {
  func entities(for identifiers: [String]) async throws -> [TaskEntity] {
    let items = Catalog.cached.tasks
    return identifiers.map { id in items.first { $0.id == id }.map(TaskEntity.init) ?? TaskEntity(id: id) }
  }

  func suggestedEntities() async throws -> [TaskEntity] {
    await freshCatalog().tasks.map(TaskEntity.init)
  }
}

struct RoutineEntity: AppEntity {
  static let typeDisplayRepresentation: TypeDisplayRepresentation = "Routine"
  static let defaultQuery = RoutineQuery()
  var id: String
  var name: String
  var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

  init(_ item: Catalog.Item) {
    id = item.id
    name = item.name
  }

  init(id: String) {
    self.id = id
    name = "Routine \(id)"
  }
}

struct RoutineQuery: EntityQuery {
  func entities(for identifiers: [String]) async throws -> [RoutineEntity] {
    let items = Catalog.cached.routines
    return identifiers.map { id in items.first { $0.id == id }.map(RoutineEntity.init) ?? RoutineEntity(id: id) }
  }

  func suggestedEntities() async throws -> [RoutineEntity] {
    await freshCatalog().routines.map(RoutineEntity.init)
  }
}

struct BoardEntity: AppEntity {
  static let typeDisplayRepresentation: TypeDisplayRepresentation = "Board"
  static let defaultQuery = BoardQuery()
  var id: String
  var name: String
  var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

  init(_ item: Catalog.Item) {
    id = item.id
    name = item.name
  }

  init(id: String) {
    self.id = id
    name = "Board \(id)"
  }
}

struct BoardQuery: EntityQuery {
  func entities(for identifiers: [String]) async throws -> [BoardEntity] {
    let items = Catalog.cached.boards
    return identifiers.map { id in items.first { $0.id == id }.map(BoardEntity.init) ?? BoardEntity(id: id) }
  }

  func suggestedEntities() async throws -> [BoardEntity] {
    await freshCatalog().boards.map(BoardEntity.init)
  }
}

struct PanelEntity: AppEntity {
  static let typeDisplayRepresentation: TypeDisplayRepresentation = "Panel"
  static let defaultQuery = PanelQuery()
  var id: String
  var name: String
  var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

  init(_ item: Catalog.Item) {
    id = item.id
    name = item.name
  }

  init(id: String) {
    self.id = id
    name = id
  }
}

struct PanelQuery: EntityQuery {
  func entities(for identifiers: [String]) async throws -> [PanelEntity] {
    let items = Catalog.cached.panels
    return identifiers.map { id in items.first { $0.id == id }.map(PanelEntity.init) ?? PanelEntity(id: id) }
  }

  func suggestedEntities() async throws -> [PanelEntity] {
    await freshCatalog().panels.map(PanelEntity.init)
  }
}

/// A hot link as something Shortcuts, widgets and Control Center can pick.
struct HotLinkEntity: AppEntity {
  static let typeDisplayRepresentation: TypeDisplayRepresentation = "Hot Link"
  static let defaultQuery = HotLinkQuery()
  var id: String
  var title: String
  var icon: String
  var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(title: "\(title)", image: .init(systemName: icon))
  }

  init(_ link: HotLink) {
    id = link.id
    title = link.title
    icon = link.icon
  }

  var link: HotLink? { HotLink.all.first { $0.id == id } }
}

struct HotLinkQuery: EntityQuery {
  func entities(for identifiers: [String]) async throws -> [HotLinkEntity] {
    HotLink.all.filter { identifiers.contains($0.id) }.map(HotLinkEntity.init)
  }

  func suggestedEntities() async throws -> [HotLinkEntity] {
    HotLink.all.map(HotLinkEntity.init)
  }
}
