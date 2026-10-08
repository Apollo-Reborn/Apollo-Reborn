import AppIntents

struct RefreshApolloSubscriptionsIntent: AppIntent {
    static let title: LocalizedStringResource = "Refresh Apollo Subscriptions Index"
    static var supportedModes: IntentModes { .background }
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let complete = try await ApolloContentService.shared.refreshSubscriptions()
        return .result(dialog: complete ? "Apollo’s eligible subscribed communities are indexed." : "Indexed the first 500 subscriptions. This account has more; existing entries were not removed.")
    }
}
