import AppIntents
import Foundation

/// Fixed r/ApolloReborn packaging proof, kept only so existing user-authored
/// shortcuts keep working. Deliberately NOT `.system.open`: Siri AI builds its
/// toolbox from schema intents, and a second subreddit open action whose query
/// only ever matches one community competed with `OpenApolloSubscribedSubredditIntent`
/// ("open boutiquebluray" resolved no entity here and fell through to search).
public struct OpenApolloProofSubredditIntent: AppIntent {
    public static let title: LocalizedStringResource = "Open Apollo Subreddit"
    public static var supportedModes: IntentModes { .foreground }
    public static var allowedExecutionTargets: IntentExecutionTargets { .main }

    @Parameter(title: "Subreddit") public var target: ApolloProofSubredditEntity

    public init() {}

    public init(target: ApolloProofSubredditEntity) {
        self.target = target
    }

    public func perform() async throws -> some IntentResult {
        guard target.id == ApolloProofSubredditEntity.community.id else {
            throw AppIntentError.Unrecoverable.entityNotFound
        }
        ApolloSiriLog.event("Open subreddit intent performed")
        try await ApolloSiriNavigation.open(URL(string: "apollo://reddit.com/r/ApolloReborn/")!)
        return .result()
    }
}
