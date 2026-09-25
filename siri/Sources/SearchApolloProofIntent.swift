import AppIntents
import Foundation

@AppIntent(schema: .system.searchInApp)
public struct SearchApolloProofIntent {
    public static let title: LocalizedStringResource = "Search Apollo"
    public static var supportedModes: IntentModes { .foreground }
    public static var allowedExecutionTargets: IntentExecutionTargets { .main }

    public var criteria: StringSearchCriteria

    public static var parameterSummary: some ParameterSummary {
        Summary("Search Apollo for \(\.$criteria)")
    }

    public init() {}

    public func perform() async throws -> some IntentResult {
        ApolloSiriLog.event("Search intent performed")
        // App Shortcut tiles can supply an empty criteria value rather than
        // resolving it first. Ask before touching Apollo's navigation state.
        let resolved = criteria.term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? try await $criteria.requestValue("What would you like to search for in Apollo?")
            : criteria
        try await ApolloSiriNavigation.search(resolved.term)
        return .result()
    }
}
