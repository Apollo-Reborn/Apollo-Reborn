import AppIntents
import Foundation

/// Controls are explicit Shortcuts actions for this opt-in build; they do not
/// create a donation per post/subreddit or clutter the App Shortcuts provider.
struct SetApolloContentIndexingIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Apollo Content Indexing"
    static let description = IntentDescription("Make eligible public posts loaded in Apollo and subscribed communities searchable in Spotlight. Turning off removes this content index. Private, NSFW, hidden and anonymous content is excluded.")
    static var supportedModes: IntentModes { .background }
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
    @Parameter(title: "Enabled") var enabled: Bool
    static var parameterSummary: some ParameterSummary { Summary("Set Apollo content indexing to \(\.$enabled)") }
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await ApolloContentService.shared.setEnabled(enabled)
        return .result(dialog: enabled ? "Indexing enabled. Browse Apollo to collect eligible public posts and subscribed communities." : "Indexing disabled and Apollo's content index cleared.")
    }
}

struct ApolloContentIndexStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Apollo Content Index Status"
    static var supportedModes: IntentModes { .background }
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let status = try await ApolloContentService.shared.status()
        return .result(value: status, dialog: "\(status)")
    }
}

struct FindApolloIndexedPostsIntent: AppIntent {
    static let title: LocalizedStringResource = "Find Indexed Apollo Posts"
    static var supportedModes: IntentModes { .background }
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
    @Parameter(title: "Search") var query: String
    static var parameterSummary: some ParameterSummary { Summary("Find indexed Apollo posts matching \(\.$query)") }
    func perform() async throws -> some IntentResult & ReturnsValue<[ApolloPostEntity]> & ProvidesDialog & ShowsSnippetIntent {
        ApolloSiriLog.event("Indexed post search action started")
        let snapshot = try await ApolloContentService.shared.searchSnapshot(query: query)
        ApolloSiriLog.event("Indexed post search returning snippet", count: snapshot.records.count)
        return .result(value: snapshot.records.map(ApolloPostEntity.init),
                       dialog: IntentDialog(full: snapshot.records.first.map { "Found \(snapshot.records.count) posts. The top one is \($0.title), in r/\($0.subreddit)." }
                                                ?? "I didn't find any matching posts you've seen in Apollo.",
                                            supporting: "Found \(snapshot.records.count) indexed posts in Apollo."),
                       snippetIntent: ApolloPostResultsSnippetIntent(records: snapshot.records, account: snapshot.account))
    }
}
