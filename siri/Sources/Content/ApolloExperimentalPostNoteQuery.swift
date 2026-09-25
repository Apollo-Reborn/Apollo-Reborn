import AppIntents
import CoreSpotlight

struct ApolloExperimentalPostNoteQuery: EntityStringQuery, IndexedEntityQuery {
    func entities(for identifiers: [String]) async throws -> [ApolloExperimentalPostNote] {
        try await ApolloSiriLog.query("Experimental note IDs") {
            guard await ApolloContentService.shared.schemaExperimentEnabled() else { return [] }
            let canonical = identifiers.compactMap { id in
                id.hasPrefix(ApolloExperimentalPostNote.prefix) ? String(id.dropFirst(ApolloExperimentalPostNote.prefix.count)) : nil
            }
            return try await ApolloContentService.shared.resolve(canonical, kind: .post).map(ApolloExperimentalPostNote.init)
        }
    }
    func entities(matching string: String) async throws -> [ApolloExperimentalPostNote] {
        try await ApolloSiriLog.query("Experimental note text match") {
            guard await ApolloContentService.shared.schemaExperimentEnabled() else { return [] }
            return try await ApolloContentService.shared.records(kind: .post, query: string).map(ApolloExperimentalPostNote.init)
        }
    }
    func suggestedEntities() async throws -> [ApolloExperimentalPostNote] {
        try await ApolloSiriLog.query("Experimental note suggestions") {
            guard await ApolloContentService.shared.schemaExperimentEnabled() else { return [] }
            return try await ApolloContentService.shared.records(kind: .post, limit: 10).map(ApolloExperimentalPostNote.init)
        }
    }
    func reindexEntities(for identifiers: [String], indexDescription: CSSearchableIndexDescription) async throws {
        try await ApolloContentService.shared.reindex(protectionClass: indexDescription.protectionClass)
    }
    func reindexAllEntities(indexDescription: CSSearchableIndexDescription) async throws {
        try await ApolloContentService.shared.reindex(protectionClass: indexDescription.protectionClass)
    }
}
