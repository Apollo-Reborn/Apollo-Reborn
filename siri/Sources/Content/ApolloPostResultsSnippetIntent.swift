import AppIntents
import SwiftUI

struct ApolloPostResultsSnippetIntent: SnippetIntent {
    static let title: LocalizedStringResource = "Apollo Post Results"
    static let isDiscoverable = false
    static var supportedModes: IntentModes { .background }
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    @Parameter(title: "Post identifiers") var identifiers: [String]
    @Parameter(title: "Account scope") var account: String

    init() {}
    init(records: [ApolloContentRecord], account: String) {
        self.identifiers = records.map(\.id)
        self.account = account
    }

    func perform() async throws -> some IntentResult & ShowsSnippetView {
        ApolloSiriLog.event("Post results snippet requested")
        let records = try await ApolloContentService.shared.snippetRecords(identifiers: identifiers, account: account)
        ApolloSiriLog.event("Post results snippet view returned", count: records.count)
        return .result(view: ApolloPostResultsView(posts: records.prefix(3).map(ApolloPostEntity.init),
                                                 totalCount: records.count))
    }
}
