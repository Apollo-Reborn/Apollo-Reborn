import AppIntents
import Foundation

/// Siri's in-app search contract is NAVIGATION: Apple defines `searchInApp`
/// as "navigates to search results" and notes Siri may not show dialog or
/// snippet output. In-Siri post results come from the Spotlight semantic index
/// (IndexedEntity + OpenApolloPostIntent), not from this action.
@AppIntent(schema: .system.searchInApp)
public struct SearchApolloIntent: ShowInAppSearchResultsIntent {
    public static let title: LocalizedStringResource = "Search Apollo"
    public static let description = IntentDescription(
        "Searches Reddit in Apollo and shows the results in Apollo's search screen.",
        searchKeywords: ["search", "find", "look up", "reddit", "posts", "subreddit"])
    public static let searchScopes: [StringSearchScope] = [.general]
    public static var supportedModes: IntentModes { .foreground }
    public static var allowedExecutionTargets: IntentExecutionTargets { .main }

    public var criteria: StringSearchCriteria

    public static var parameterSummary: some ParameterSummary {
        Summary("Search Apollo for \(\.$criteria)")
    }

    public init() {}

    public func perform() async throws -> some IntentResult {
        ApolloSiriLog.event("Search-in-app action started; foreground navigation")
        // Callers may supply empty criteria. Ask before touching navigation.
        let resolved = criteria.term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? try await $criteria.requestValue("What would you like to search for in Apollo?")
            : criteria
        try await ApolloSiriNavigation.search(resolved.term)
        ApolloSiriLog.event("Search-in-app action completed; no snippet")
        return .result()
    }
}
