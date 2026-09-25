import AppIntents
import Foundation

@AppIntent(schema: .system.open)
struct OpenApolloExperimentalPostIntent {
    static let title: LocalizedStringResource = "Open Experimental Apollo Post"
    static var supportedModes: IntentModes { .foreground }
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
    var target: ApolloExperimentalPostNote
    func perform() async throws -> some IntentResult {
        guard await ApolloContentService.shared.schemaExperimentEnabled(),
              target.id.hasPrefix(ApolloExperimentalPostNote.prefix) else { throw AppIntentError.Unrecoverable.entityNotFound }
        let id = String(target.id.dropFirst(ApolloExperimentalPostNote.prefix.count))
        guard let record = try await ApolloContentService.shared.resolve([id], kind: .post).first,
              let url = URL(string: record.route) else { throw AppIntentError.Unrecoverable.entityNotFound }
        try await ApolloSiriNavigation.open(url)
        return .result()
    }
}
