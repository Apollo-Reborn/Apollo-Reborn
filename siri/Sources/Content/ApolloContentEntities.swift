import AppIntents
import CoreSpotlight
import CoreTransferable
import Foundation

struct ApolloPostEntity: IndexedEntity {
    // Synonyms are what Siri matches when someone names the kind of thing
    // ("the post", "that thread") rather than the entity itself.
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Reddit Post", synonyms: ["Post", "Reddit Thread", "Thread"])
    static let defaultQuery = ApolloPostQuery()
    let id: String
    let expiresAt: Date
    /// Public HTTPS permalink for sharing to other apps. Local navigation keeps
    /// using the record's `apollo://` route (see OpenApolloPostIntent).
    let webURL: URL
    @Property(title: "Title") var title: String
    @Property(title: "Subreddit") var subreddit: String
    @Property(title: "Author") var author: String
    // Apple: wrapped properties with an indexingKey feed the Spotlight semantic
    // index directly; Apple Intelligence uses that index to find content even
    // when it's described vaguely ("the Apollo post about keyboards").
    @Property(title: "Text", indexingKey: \.textContent) var text: String
    @Property(title: "Posted", indexingKey: \.contentCreationDate) var createdAt: Date

    init(_ record: ApolloContentRecord) {
        id = record.id
        expiresAt = record.observedAt.addingTimeInterval(30 * 24 * 60 * 60)
        webURL = ApolloContentRecord.webURL(forRoute: record.route)
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
        attributes.authorNames = [author]
        attributes.url = webURL
        attributes.keywords = [subreddit, "r/\(subreddit)", "Apollo", "Reddit"]
        return attributes
    }
    /// Plain-text export: what "send this to …" should carry into Messages/Mail.
    var shareText: String { "\(title)\n\(webURL.absoluteString)" }
}

// Cross-app transfer ("send this post to Sam", "remind me about this"). The
// HTTPS permalink comes first so link-aware receivers get a rich link; text is
// the fallback. Never export the apollo:// route; it only works inside Apollo.
extension ApolloPostEntity: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(exporting: \.webURL)
        ProxyRepresentation(exporting: \.shareText)
    }
}

struct ApolloSubredditEntity: IndexedEntity {
    // Display name stays generic ("Subreddit"), not "Subscribed Subreddit": Siri
    // matches this and its synonyms against how people actually speak.
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Subreddit", synonyms: ["Community", "Sub", "Reddit Community"])
    static let defaultQuery = ApolloSubredditQuery()
    let id: String
    let expiresAt: Date
    let webURL: URL
    @Property(title: "Name") var name: String
    @Property(title: "Description", indexingKey: \.contentDescription) var summary: String
    /// Spoken aliases: bare name and the community's own display title. Siri
    /// hears "open boutique blu-ray", never "open r/boutiquebluray".
    let aliases: [String]
    init(_ record: ApolloContentRecord) {
        var spoken = [record.subreddit]
        if let title = record.displayTitle, !title.isEmpty, title.caseInsensitiveCompare(record.subreddit) != .orderedSame {
            spoken.append(title)
        }
        id = record.id
        expiresAt = record.observedAt.addingTimeInterval(30 * 24 * 60 * 60)
        webURL = ApolloContentRecord.webURL(forRoute: record.route)
        aliases = spoken
        name = record.title; summary = record.text
    }
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(summary)",
                              image: .init(systemName: "bubble.left.and.bubble.right"),
                              synonyms: aliases.map { "\($0)" })
    }
    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        attributes.title = name
        attributes.alternateNames = aliases
        attributes.textContent = summary
        attributes.url = webURL
        attributes.keywords = ["Apollo", "Reddit", "subreddit", "community"] + aliases
        return attributes
    }
}

extension ApolloSubredditEntity: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(exporting: \.webURL)
    }
}

struct ApolloPostQuery: EntityStringQuery, IndexedEntityQuery {
    func reindexEntities(for identifiers: [String], indexDescription: CSSearchableIndexDescription) async throws {
        try await ApolloContentService.shared.reindex(identifiers, protectionClass: indexDescription.protectionClass)
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
        try await ApolloContentService.shared.reindex(identifiers, protectionClass: indexDescription.protectionClass)
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
