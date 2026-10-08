import AppIntents

struct SearchApolloPostsIntent: AppIntent {
    static let title: LocalizedStringResource = "Search Apollo Posts"
    static let description = IntentDescription("Search Reddit using Apollo’s signed-in account and show matching public posts here. Requires Apollo content indexing to be enabled.")
    static var supportedModes: IntentModes { .background }
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
    @Parameter(title: "Search") var query: String
    static var parameterSummary: some ParameterSummary { Summary("Search Apollo posts for \(\.$query)") }

    func perform() async throws -> some IntentResult & ReturnsValue<[ApolloPostEntity]> & ProvidesDialog & ShowsSnippetIntent {
        ApolloSiriLog.event("Live post search action started")
        let result = try await ApolloContentService.shared.liveSearch(query: query)
        ApolloSiriLog.event("Live post search returning snippet", count: result.records.count)
        return .result(value: result.records.map(ApolloPostEntity.init),
                       // Full text for voice-only contexts; supporting text sits beside the snippet.
                       dialog: IntentDialog(full: result.records.first.map { "Found \(result.records.count) posts. The top one is \($0.title), in r/\($0.subreddit)." }
                                                ?? "I didn't find any matching posts in Apollo.",
                                            supporting: "Found \(result.records.count) posts from Reddit."),
                       snippetIntent: ApolloPostResultsSnippetIntent(records: result.records, account: result.account))
    }
}
