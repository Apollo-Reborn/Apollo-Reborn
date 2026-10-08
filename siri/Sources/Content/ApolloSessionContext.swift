import Foundation

/// A Reddit comment Apollo has already loaded for a post the person opened.
/// Foundation-only (host-testable). Never persisted, never Spotlight-indexed:
/// Apple treats per-parent child content like this as context reached through
/// its parent and onscreen annotations, not as independently indexed items.
struct ApolloCommentRecord: Sendable, Equatable, Identifiable {
    let id: String          // reddit:comment:t1_<id>
    let postID: String      // reddit:post:t3_<id>
    let subreddit: String
    let author: String
    let body: String
    let score: Int?
    let depth: Int
    let isOP: Bool
    let createdAt: Date
    let order: Int          // Apollo's thread order when captured

    static func identifier(_ fullName: String?) -> String? {
        guard let name = fullName?.lowercased(), name.hasPrefix("t1_"),
              ApolloContentRecord.validName(String(name.dropFirst(3))) else { return nil }
        return "reddit:comment:\(name)"
    }

    /// `json` mirrors Reddit's comment keys; the tweak builds it from RDKComment.
    static func parse(_ json: [String: Any], order: Int) -> Self? {
        guard let id = identifier(json["name"] as? String),
              var link = (json["link_id"] as? String)?.lowercased() else { return nil }
        if !link.hasPrefix("t3_") { link = "t3_" + link }
        guard let postID = ApolloContentRecord.identifier(["kind": "t3", "name": link]),
              let subreddit = json["subreddit"] as? String, ApolloContentRecord.validName(subreddit) else { return nil }
        let author = (json["author"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let body = (json["body"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // Same exclusions as the rest of the integration: nothing deleted/removed.
        guard !author.isEmpty, author != "[deleted]", !body.isEmpty,
              body != "[deleted]", body != "[removed]" else { return nil }
        let timestamp = (json["created_utc"] as? NSNumber)?.doubleValue ?? 0
        return Self(id: id, postID: postID, subreddit: subreddit, author: String(author.prefix(64)),
                    body: String(body.prefix(2000)), score: (json["score"] as? NSNumber)?.intValue,
                    depth: max(0, (json["depth"] as? NSNumber)?.intValue ?? 0),
                    isOP: json["is_submitter"] as? Bool ?? false,
                    createdAt: Date(timeIntervalSince1970: timestamp.isFinite ? timestamp : 0), order: order)
    }

    /// Native route to the comment in its thread (never an untrusted link).
    var route: String {
        "apollo://reddit.com/r/\(subreddit)/comments/\(postID.dropFirst("reddit:post:t3_".count))/_/\(id.dropFirst("reddit:comment:t1_".count))/"
    }
}

/// In-memory, account-scoped context for what the person is looking at right
/// now: posts they opened (even ones no listing captured, e.g. from a link) and
/// the comments Apollo loaded for them. This is what lets onscreen annotations
/// resolve for any visible post/comment without widening what gets persisted
/// or indexed. Access only from the content-service actor (or a host test).
final class ApolloSessionContext {
    let postLimit: Int
    let threadLimit: Int
    let commentsPerThread: Int
    private(set) var account: String?
    private var posts: [String: ApolloContentRecord] = [:]
    private var postOrder: [String] = []          // most recent last
    private var threads: [String: [String: ApolloCommentRecord]] = [:]
    private var threadOrder: [String] = []        // most recent last

    init(postLimit: Int = 50, threadLimit: Int = 5, commentsPerThread: Int = 500) {
        self.postLimit = postLimit
        self.threadLimit = threadLimit
        self.commentsPerThread = commentsPerThread
    }

    /// Any scope change (account switch, logout, opt-out) drops everything.
    func configure(account: String?) {
        guard account != self.account else { return }
        self.account = account
        posts.removeAll(); postOrder.removeAll()
        threads.removeAll(); threadOrder.removeAll()
    }

    func observe(post record: ApolloContentRecord, account: String) {
        guard account == self.account, record.kind == .post else { return }
        posts[record.id] = record
        postOrder.removeAll { $0 == record.id }
        postOrder.append(record.id)
        while postOrder.count > postLimit { posts.removeValue(forKey: postOrder.removeFirst()) }
    }

    func observe(comments: [ApolloCommentRecord], account: String) {
        guard account == self.account else { return }
        for comment in comments {
            // Most recently loaded thread last; evict the oldest beyond the cap.
            threadOrder.removeAll { $0 == comment.postID }
            threadOrder.append(comment.postID)
            while threadOrder.count > threadLimit { threads.removeValue(forKey: threadOrder.removeFirst()) }
            var thread = threads[comment.postID] ?? [:]
            // Keep the first-seen thread position; refresh text/score in place.
            let order = thread[comment.id]?.order ?? comment.order
            guard thread[comment.id] != nil || thread.count < commentsPerThread else { continue }
            thread[comment.id] = ApolloCommentRecord(id: comment.id, postID: comment.postID, subreddit: comment.subreddit,
                                                     author: comment.author, body: comment.body, score: comment.score,
                                                     depth: comment.depth, isOP: comment.isOP,
                                                     createdAt: comment.createdAt, order: order)
            threads[comment.postID] = thread
        }
    }

    func post(_ id: String) -> ApolloContentRecord? { posts[id] }

    func comments(_ ids: [String]) -> [ApolloCommentRecord] {
        ids.compactMap { id in threads.values.lazy.compactMap { $0[id] }.first }
    }

    /// A representative set, not just the first rows: favour score (consensus),
    /// OP replies and top-level comments, keep a mild thread-order bias.
    /// Mirrors the ranking ApolloAISummary uses for the same material.
    func comments(forPost postID: String, limit: Int) -> [ApolloCommentRecord] {
        guard let thread = threads[postID], limit > 0 else { return [] }
        func rank(_ c: ApolloCommentRecord) -> Int {
            min(max(c.score ?? 0, -50), 5000) + (c.isOP ? 1400 : 0) - min(c.depth, 8) * 70 - min(c.order, 100) * 3
        }
        return thread.values.sorted { rank($0) == rank($1) ? $0.order < $1.order : rank($0) > rank($1) }
            .prefix(limit).map { $0 }
    }

    func search(_ query: String, limit: Int) -> [ApolloCommentRecord] {
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return [] }
        let matches = threads.values.flatMap(\.values).filter { c in
            let text = "\(c.body) \(c.author)".lowercased()
            return terms.allSatisfy { text.contains($0) }
        }
        return Array(matches.sorted { ($0.score ?? 0) > ($1.score ?? 0) }.prefix(limit))
    }

    /// Hide/delete: drop the post and any comment thread belonging to it.
    func suppress(_ ids: [String]) {
        for id in ids {
            posts.removeValue(forKey: id)
            postOrder.removeAll { $0 == id }
            threads.removeValue(forKey: id)
            threadOrder.removeAll { $0 == id }
        }
    }
}
