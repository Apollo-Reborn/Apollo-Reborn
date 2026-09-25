import AppIntents
import CoreSpotlight
import SwiftUI

public struct ShowApolloSiriProofIntent: AppIntent {
    public static let title: LocalizedStringResource = "Show Apollo Community"
    public static let description = IntentDescription("Show the Apollo Reborn community.")
    public static var supportedModes: IntentModes { .background }
    public static var allowedExecutionTargets: IntentExecutionTargets { .main }

    public init() {}

    public func perform() async throws -> some ReturnsValue<ApolloProofSubredditEntity>
        & ProvidesDialog & ShowsSnippetView {
        ApolloSiriLog.event("Community snippet intent performed")
        let entity = ApolloProofSubredditEntity.community
        // One explicit action seeds one public item for the Spotlight proof.
        // No background crawling, account data, or browsing-history donation.
        try await CSSearchableIndex.default().indexAppEntities([entity])
        ApolloSiriLog.event("Indexed fixed subreddit")
        return .result(value: entity, dialog: "The Apollo Reborn community is r/ApolloReborn.",
                       view: ApolloProofSnippetView(subreddit: entity))
    }
}
