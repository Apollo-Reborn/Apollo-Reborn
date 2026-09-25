import AppIntents
import Foundation

public struct ApolloProofSubredditQuery: EntityStringQuery {
    public init() {}

    public func entities(for identifiers: [String]) async throws -> [ApolloProofSubredditEntity] {
        ApolloSiriLog.event("Resolve subreddit IDs")
        let entity = ApolloProofSubredditEntity.community
        return identifiers.contains(entity.id) ? [entity] : []
    }

    public func suggestedEntities() async throws -> [ApolloProofSubredditEntity] {
        ApolloSiriLog.event("Suggest fixed subreddit")
        return [.community]
    }

    public func entities(matching string: String) async throws -> [ApolloProofSubredditEntity] {
        // Never log the search string, even while this catalogue is fixed.
        ApolloSiriLog.event("Search fixed subreddit catalogue")
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let entity = ApolloProofSubredditEntity.community
        return query.isEmpty || entity.name.localizedStandardContains(query)
            || entity.summary.localizedStandardContains(query) ? [entity] : []
    }
}
