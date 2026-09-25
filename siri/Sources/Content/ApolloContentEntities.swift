import AppIntents
import CoreSpotlight
import Foundation

struct ApolloPostEntity: IndexedEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Reddit Post"
    static let defaultQuery = ApolloPostQuery()
    let id: String
    let expiresAt: Date
    @Property(title: "Title") var title: String
    @Property(title: "Subreddit") var subreddit: String
    @Property(title: "Author") var author: String
    @Property(title: "Text") var text: String
    @Property(title: "Posted") var createdAt: Date

    init(_ record: ApolloContentRecord) {
        id = record.id
        expiresAt = record.observedAt.addingTimeInterval(30 * 24 * 60 * 60)
        title = record.title; subreddit = record.subreddit
        author = record.author; text = record.text; createdAt = record.createdAt
    }
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "r/\(subreddit) · u/\(author)", image: .init(systemName: "text.bubble"))
    }
    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        attributes.title = title
        attributes.contentDescription = "r/\(subreddit) · u/\(author)\n\(text)"
        attributes.textContent = "\(title)\n\(text)"
        attributes.contentCreationDate = createdAt
        attributes.authorNames = [author]
        attributes.keywords = [subreddit, "r/\(subreddit)", "Apollo", "Reddit"]
        return attributes
    }
}

struct ApolloSubredditEntity: IndexedEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Subscribed Subreddit"
    static let defaultQuery = ApolloSubredditQuery()
    let id: String
    let expiresAt: Date
    @Property(title: "Name") var name: String
    @Property(title: "Description") var summary: String
    init(_ record: ApolloContentRecord) {
        id = record.id
        expiresAt = record.observedAt.addingTimeInterval(30 * 24 * 60 * 60)
        name = record.title; summary = record.text
    }
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(summary)", image: .init(systemName: "bubble.left.and.bubble.right"))
    }
    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        attributes.title = name
        attributes.contentDescription = summary
        attributes.textContent = summary
        attributes.keywords = ["Apollo", "Reddit", "subreddit", name]
        return attributes
    }
}

struct ApolloPostQuery: EntityStringQuery, IndexedEntityQuery {
    func reindexEntities(for identifiers: [String], indexDescription: CSSearchableIndexDescription) async throws {
        try await ApolloContentService.shared.reindex(protectionClass: indexDescription.protectionClass)
    }
    func reindexAllEntities(indexDescription: CSSearchableIndexDescription) async throws {
        try await ApolloContentService.shared.reindex(protectionClass: indexDescription.protectionClass)
    }
    func entities(for identifiers: [String]) async throws -> [ApolloPostEntity] {
        try await ApolloSiriLog.query("Post IDs") {
            try await ApolloContentService.shared.resolve(identifiers, kind: .post).map(ApolloPostEntity.init)
        }
    }
    func entities(matching string: String) async throws -> [ApolloPostEntity] {
        try await ApolloSiriLog.query("Post text match") {
            try await ApolloContentService.shared.records(kind: .post, query: string).map(ApolloPostEntity.init)
        }
    }
    func suggestedEntities() async throws -> [ApolloPostEntity] {
        try await ApolloSiriLog.query("Post suggestions") {
            try await ApolloContentService.shared.records(kind: .post, limit: 10).map(ApolloPostEntity.init)
        }
    }
}

struct ApolloSubredditQuery: EntityStringQuery, IndexedEntityQuery {
    func reindexEntities(for identifiers: [String], indexDescription: CSSearchableIndexDescription) async throws {
        try await ApolloContentService.shared.reindex(protectionClass: indexDescription.protectionClass)
    }
    func reindexAllEntities(indexDescription: CSSearchableIndexDescription) async throws {
        try await ApolloContentService.shared.reindex(protectionClass: indexDescription.protectionClass)
    }
    func entities(for identifiers: [String]) async throws -> [ApolloSubredditEntity] {
        try await ApolloSiriLog.query("Subscribed subreddit IDs") {
            try await ApolloContentService.shared.resolve(identifiers, kind: .subreddit).map(ApolloSubredditEntity.init)
        }
    }
    func entities(matching string: String) async throws -> [ApolloSubredditEntity] {
        try await ApolloSiriLog.query("Subscribed subreddit text match") {
            try await ApolloContentService.shared.records(kind: .subreddit, query: string).map(ApolloSubredditEntity.init)
        }
    }
    func suggestedEntities() async throws -> [ApolloSubredditEntity] {
        try await ApolloSiriLog.query("Subscribed subreddit suggestions") {
            try await ApolloContentService.shared.records(kind: .subreddit, limit: 10).map(ApolloSubredditEntity.init)
        }
    }
}

@AppIntent(schema: .system.open)
struct OpenApolloPostIntent {
    static let title: LocalizedStringResource = "Open Apollo Post"
    static var supportedModes: IntentModes { .foreground }
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
    var target: ApolloPostEntity
    init() {}
    init(target: ApolloPostEntity) { self.target = target }
    func perform() async throws -> some IntentResult {
        ApolloSiriLog.event("Open post action started")
        guard let record = try await ApolloContentService.shared.resolve([target.id], kind: .post).first,
              let url = URL(string: record.route) else { throw AppIntentError.Unrecoverable.entityNotFound }
        try await ApolloSiriNavigation.open(url)
        ApolloSiriLog.event("Open post action completed")
        return .result()
    }
}

@AppIntent(schema: .system.open)
struct OpenApolloSubscribedSubredditIntent {
    static let title: LocalizedStringResource = "Open Subscribed Apollo Community"
    static var supportedModes: IntentModes { .foreground }
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
    var target: ApolloSubredditEntity
    func perform() async throws -> some IntentResult {
        ApolloSiriLog.event("Open subscribed subreddit action started")
        guard let record = try await ApolloContentService.shared.resolve([target.id], kind: .subreddit).first,
              let url = URL(string: record.route) else { throw AppIntentError.Unrecoverable.entityNotFound }
        try await ApolloSiriNavigation.open(url)
        ApolloSiriLog.event("Open subscribed subreddit action completed")
        return .result()
    }
}
