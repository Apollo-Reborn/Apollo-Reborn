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
        // No longer indexed: the fixed proof entity duplicated r/ApolloReborn
        // in Spotlight/Siri next to the real subscribed-community entity.
        return .result(value: entity, dialog: "The Apollo Reborn community is r/ApolloReborn.",
                       view: ApolloProofSnippetView(subreddit: entity))
    }
}
