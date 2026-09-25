import AppIntents

// The note schema requires the OPTIONAL folder property to have this schema
// type. Apollo has no note folders, so queries are empty and note.folder is nil.
@AppEntity(schema: .notes.folder)
struct ApolloExperimentalPostFolder {
    static let defaultQuery = ApolloExperimentalPostFolderQuery()
    let id: String
    var name: String
    @ComputedProperty var parentFolder: ApolloExperimentalPostFolder? { nil }
    var account: ApolloExperimentalPostAccount?
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct ApolloExperimentalPostFolderQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [ApolloExperimentalPostFolder] { [] }
    func suggestedEntities() async throws -> [ApolloExperimentalPostFolder] { [] }
}
