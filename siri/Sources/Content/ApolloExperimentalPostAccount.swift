import AppIntents

@AppEntity(schema: .notes.account)
struct ApolloExperimentalPostAccount {
    static let defaultQuery = ApolloExperimentalPostAccountQuery()
    let id: String
    var name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct ApolloExperimentalPostAccountQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [ApolloExperimentalPostAccount] { [] }
    func suggestedEntities() async throws -> [ApolloExperimentalPostAccount] { [] }
}
