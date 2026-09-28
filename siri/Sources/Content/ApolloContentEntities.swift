import AppIntents
import CoreSpotlight
import CoreTransferable
import Foundation

struct ApolloPostEntity: IndexedEntity {
    // Synonyms are what Siri matches when someone names the kind of thing
    // ("the post", "that thread") rather than the entity itself; numericFormat
    // lets it phrase counts ("3 posts") naturally.
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Reddit Post", numericFormat: "\(placeholder: .int) Reddit posts",
        synonyms: ["Post", "Reddit Thread", "Thread"])
    static let defaultQuery = ApolloPostQuery()
    let id: String
    let expiresAt: Date
    @Property(title: "Title") var title: String
    @Property(title: "Subreddit") var subreddit: String
    @Property(title: "Author") var author: String
    // Apple: wrapped properties with an indexingKey feed the Spotlight semantic
    // index directly; Apple Intelligence uses that index to find content even
    // when it's described vaguely ("the Apollo post about keyboards").
    @Property(title: "Text", indexingKey: \.textContent) var text: String
    @Property(title: "Posted", indexingKey: \.contentCreationDate) var createdAt: Date
    /// Public HTTPS permalink (URL is a supported entity property type). Local
    /// navigation keeps using the record's `apollo://` route.
    @Property(title: "Link", indexingKey: \.url) var webURL: URL
    @Property(title: "Score") var score: Int?
    @Property(title: "Comment Count") var commentCount: Int?
    @Property(title: "Linked Site") var linkDomain: String?

    /// Comments Apollo has ALREADY loaded because the person opened this post.
    /// Deferred (Apple: large values loaded lazily, excluded from archives) and
    /// served from memory only: resolving it never issues a Reddit request, so
    /// Siri answering "what are the comments saying" costs nothing and works
    /// beyond what is visible on screen. Empty for posts never opened.
    @DeferredProperty(title: "Loaded Comments")
    var loadedComments: [ApolloCommentEntity] {
        get async throws {
            try await ApolloContentService.shared.comments(forPost: id, limit: 40).map(ApolloCommentEntity.init)
        }
    }

    init(_ record: ApolloContentRecord) {
        id = record.id
        expiresAt = record.observedAt.addingTimeInterval(30 * 24 * 60 * 60)
        title = record.title; subreddit = record.subreddit
        author = record.author; text = record.text; createdAt = record.createdAt
        webURL = ApolloContentRecord.webURL(forRoute: record.route)
        score = record.score; commentCount = record.commentCount; linkDomain = record.linkDomain
    }
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "r/\(subreddit) · u/\(author)",
                              image: .init(systemName: "text.bubble"))
    }
    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        attributes.title = title
        attributes.contentDescription = "r/\(subreddit) · u/\(author)\n\(text)"
        attributes.authorNames = [author]
        attributes.keywords = [subreddit, "r/\(subreddit)", "Apollo", "Reddit"] + (linkDomain.map { [$0] } ?? [])
        return attributes
    }
    /// Readable export: what "send this to …" / "summarize this" should carry.
    var plainText: String {
        [title, "r/\(subreddit) · u/\(author)", text, webURL.absoluteString]
            .filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}

// Cross-app transfer ("send this post to Sam", "add this to my notes"). The
// HTTPS permalink comes first so link-aware receivers get a rich link; plain
// text carries the content itself. Never export the apollo:// route.
extension ApolloPostEntity: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(exporting: \.webURL)
        DataRepresentation(exportedContentType: .plainText) { Data($0.plainText.utf8) }
    }
}

/// A comment on a post the person opened. Plain AppEntity, NOT IndexedEntity:
/// comments are reached through their post (`loadedComments`) and through
/// onscreen annotations ("what does this comment mean", "send this reply to
/// Sam"), like Apple's per-parent participation types. Resolution is served
/// from the memory-only session context and disappears with it.
struct ApolloCommentEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Reddit Comment", numericFormat: "\(placeholder: .int) Reddit comments",
        synonyms: ["Comment", "Reply"])
    static let defaultQuery = ApolloCommentQuery()
    let id: String
    let postID: String
    let route: String
    @Property(title: "Text") var body: String
    @Property(title: "Author") var author: String
    @Property(title: "Score") var score: Int?
    @Property(title: "Written by Original Poster") var isOriginalPoster: Bool
    @Property(title: "Reply Depth") var depth: Int
    @Property(title: "Posted") var createdAt: Date
    @Property(title: "Subreddit") var subreddit: String
    @Property(title: "Link") var webURL: URL

    init(_ record: ApolloCommentRecord) {
        id = record.id; postID = record.postID; route = record.route
        body = record.body; author = record.author; score = record.score
        isOriginalPoster = record.isOP; depth = record.depth; createdAt = record.createdAt
        subreddit = record.subreddit
        webURL = ApolloContentRecord.webURL(forRoute: record.route)
    }
    var displayRepresentation: DisplayRepresentation {
        // Apple's message entity titles with its body; do the same, bounded.
        DisplayRepresentation(title: "\(String(body.prefix(140)))",
                              subtitle: "u/\(author)\(isOriginalPoster ? " (OP)" : "") · r/\(subreddit)",
                              image: .init(systemName: "text.bubble"))
    }
    var plainText: String { "u/\(author): \(body)\n\n\(webURL.absoluteString)" }
}

extension ApolloCommentEntity: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(exporting: \.webURL)
        DataRepresentation(exportedContentType: .plainText) { Data($0.plainText.utf8) }
    }
}

struct ApolloCommentQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [ApolloCommentEntity] {
        try await ApolloSiriLog.query("Comment IDs") {
            try await ApolloContentService.shared.comments(identifiers).map(ApolloCommentEntity.init)
        }
    }
    func entities(matching string: String) async throws -> [ApolloCommentEntity] {
        try await ApolloSiriLog.query("Comment text match") {
            try await ApolloContentService.shared.searchComments(string, limit: 20).map(ApolloCommentEntity.init)
        }
    }
    func suggestedEntities() async throws -> [ApolloCommentEntity] { [] }
}

struct ApolloSubredditEntity: IndexedEntity {
    // Display name stays generic ("Subreddit"), not "Subscribed Subreddit": Siri
    // matches this and its synonyms against how people actually speak.
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Subreddit", numericFormat: "\(placeholder: .int) subreddits",
        synonyms: ["Community", "Sub", "Reddit Community"])
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
    @Parameter(title: "Post", requestValueDialog: "Which post?") var target: ApolloPostEntity
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
    @Parameter(title: "Subreddit", requestValueDialog: "Which subreddit?") var target: ApolloSubredditEntity
    init() {}
    init(target: ApolloSubredditEntity) { self.target = target }
    func perform() async throws -> some IntentResult {
        ApolloSiriLog.event("Open subscribed subreddit action started")
        guard let record = try await ApolloContentService.shared.resolve([target.id], kind: .subreddit).first,
              let url = URL(string: record.route) else { throw AppIntentError.Unrecoverable.entityNotFound }
        try await ApolloSiriNavigation.open(url)
        ApolloSiriLog.event("Open subscribed subreddit action completed")
        return .result()
    }
}

@AppIntent(schema: .system.open)
struct OpenApolloCommentIntent {
    static let title: LocalizedStringResource = "Open Apollo Comment"
    static var supportedModes: IntentModes { .foreground }
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
    @Parameter(title: "Comment", requestValueDialog: "Which comment?") var target: ApolloCommentEntity
    init() {}
    init(target: ApolloCommentEntity) { self.target = target }
    func perform() async throws -> some IntentResult {
        ApolloSiriLog.event("Open comment action started")
        guard let record = try await ApolloContentService.shared.comments([target.id]).first,
              let url = URL(string: record.route) else { throw AppIntentError.Unrecoverable.entityNotFound }
        try await ApolloSiriNavigation.open(url)
        ApolloSiriLog.event("Open comment action completed")
        return .result()
    }
}
