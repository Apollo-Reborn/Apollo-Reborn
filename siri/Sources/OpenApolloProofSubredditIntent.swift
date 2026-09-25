import AppIntents
import Foundation

@AppIntent(schema: .system.open)
public struct OpenApolloProofSubredditIntent {
    public static let title: LocalizedStringResource = "Open Apollo Subreddit"
    public static var supportedModes: IntentModes { .foreground }
    public static var allowedExecutionTargets: IntentExecutionTargets { .main }

    public var target: ApolloProofSubredditEntity

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
