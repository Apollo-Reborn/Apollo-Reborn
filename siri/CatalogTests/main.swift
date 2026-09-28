import Foundation

let directory = FileManager.default.temporaryDirectory.appendingPathComponent("apollo-catalog-tests-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: directory) }
let file = directory.appendingPathComponent("catalog.json")
let now = Date(timeIntervalSince1970: 1_800_000_000)
let account = "test-account-fingerprint"
var assertions = 0
@MainActor func check(_ condition: Bool, _ message: String) {
    assertions += 1
    guard condition else { fatalError(message) }
}
func post(_ name: String, title: String = "Café and iPhone Duo") -> [String: Any] {
    ["kind": "t3", "name": "t3_\(name)", "title": title, "subreddit": "apple", "author": "testuser",
     "selftext": "Searchable body", "subreddit_type": "public", "hidden": false, "over_18": false,
     "created_utc": now.timeIntervalSince1970]
}
func data(_ rows: [[String: Any]]) throws -> Data { try JSONSerialization.data(withJSONObject: rows) }

do {
    let store = try ApolloContentCatalog(file: file, postLimit: 2, subredditLimit: 1, retention: 100)
    try store.ingest(data([post("a")]), account: account, now: now)
    check(store.state.records.isEmpty, "Disabled store collected data")
    try store.configure(enabled: true, account: account)
    try store.ingest(data([post("a"), post("a")]), account: account, now: now)
    check(store.records(now: now).count == 1, "Repeated records duplicated")
    check(store.records(query: "CAFE duo", now: now).count == 1, "Case/diacritic/token matching failed")
    check(store.records(query: "missing", now: now).isEmpty, "Unexpected search match")
    check(store.resolve(["reddit:post:t3_a", "missing"], now: now).count == 1, "Batch resolution failed")
    check(store.records(limit: 0, now: now).isEmpty, "Zero limit failed")
    let reopened = try ApolloContentCatalog(file: file, postLimit: 2, subredditLimit: 1, retention: 100)
    check(reopened.records(now: now).count == 1, "Cold reload lost record")
    try store.ingest(data([post("a", title: "Updated")]), account: account, now: now)
    check(store.records(now: now).first?.title == "Updated", "Upsert didn't update")
    for field in ["over_18", "hidden"] {
        var rejected = post("a"); rejected[field] = true
        try store.ingest(data([rejected]), account: account, now: now)
        check(store.records(now: now).isEmpty, "Privacy change didn't remove prior post")
        try store.ingest(data([post("a")]), account: account, now: now)
    }
    for (field, value) in [("subreddit_type", "private"), ("removed_by_category", "deleted"),
                           ("selftext", "[removed]"), ("author", "[deleted]")] {
        var rejected = post("a"); rejected[field] = value
        try store.ingest(data([rejected]), account: account, now: now)
        check(store.records(now: now).isEmpty, "Sensitive/deleted post survived: \(field)")
        try store.ingest(data([post("a")]), account: account, now: now)
    }
    var missing = post("a"); missing.removeValue(forKey: "over_18")
    try store.ingest(data([missing]), account: account, now: now)
    check(store.records(now: now).isEmpty, "Missing privacy flag wasn't fail-closed")
    try store.ingest(data([post("a"), post("b"), post("c")]), account: account, now: now)
    check(store.records(now: now).count == 2, "Retention count exceeded")
    check(store.records(now: now.addingTimeInterval(101)).isEmpty, "Expired records resolved")
    try store.expire(now: now.addingTimeInterval(101))
    check(store.state.records.isEmpty, "Expiry wasn't persisted")
    var subreddit: [String: Any] = ["kind": "t5", "display_name": "Apple", "title": "Apple",
                                    "subreddit_type": "public", "over18": false, "user_is_subscriber": true]
    try store.ingest(data([subreddit]), account: account, now: now)
    check(store.records(now: now).first?.id == "reddit:subreddit:apple", "Community ID unstable")
    check(store.records(kind: .subreddit, query: "apple", now: now).count == 1, "Native community payload wasn't searchable")
    var nsfwCommunity = subreddit
    nsfwCommunity["over18"] = true
    nsfwCommunity["over_18"] = false // The post flag must not override the community flag.
    try store.ingest(data([nsfwCommunity]), account: account, now: now)
    check(store.records(kind: .subreddit, now: now).isEmpty, "NSFW community wasn't removed")
    var missingCommunityFlag = subreddit
    missingCommunityFlag.removeValue(forKey: "over18")
    missingCommunityFlag["over_18"] = false
    check(ApolloContentRecord.parse(missingCommunityFlag, now: now) == nil, "Post flag incorrectly accepted for community")
    var missingPostFlag = post("a")
    missingPostFlag.removeValue(forKey: "over_18")
    missingPostFlag["over18"] = false
    check(ApolloContentRecord.parse(missingPostFlag, now: now) == nil, "Community flag incorrectly accepted for post")
    try store.ingest(data([subreddit]), account: account, now: now)
    subreddit["user_is_subscriber"] = false
    try store.ingest(data([subreddit]), account: account, now: now)
    check(store.records(now: now).isEmpty, "Unsubscribed community retained")
    var outbound = post("a"); outbound["permalink"] = "https://evil.invalid/"
    try store.ingest(data([outbound]), account: account, now: now)
    check(store.records(now: now).first?.route == "apollo://reddit.com/r/apple/comments/a/", "Untrusted route accepted")
    try store.configure(enabled: true, account: "other-account")
    check(store.records(now: now).isEmpty, "Account switch retained previous content")
    try store.ingest(data([post("a")]), account: account, now: now)
    check(store.records(now: now).isEmpty, "Old in-flight account response accepted")
    try store.configure(enabled: false, account: account)
    check(try ApolloContentCatalog(file: file).state.records.isEmpty, "Disabled data survived restart")
    try store.configure(enabled: true, account: nil)
    try store.ingest(data([post("a")]), account: account, now: now)
    check(store.records(now: now).isEmpty, "Anonymous collection allowed")
    check(ApolloContentRecord.parse(post("../escape"), now: now) == nil, "Invalid identifier allowed")
    try store.configure(enabled: true, account: account)
    try store.ingest(data([post("a")]), account: account, now: now)
    try store.suppress(["reddit:post:t3_a"], account: account, now: now)
    check(store.records(now: now).isEmpty, "Hide did not remove record")
    try store.ingest(data([post("a")]), account: account, now: now)
    check(store.records(now: now).isEmpty, "Late listing resurrected hidden post")
    let suppressedReload = try ApolloContentCatalog(file: file)
    check(suppressedReload.state.suppressed?["reddit:post:t3_a"] != nil, "Tombstone lost on restart")
    try store.allow(["reddit:post:t3_a"], account: "wrong-account")
    check(store.state.suppressed?["reddit:post:t3_a"] != nil, "Old account undid tombstone")
    try store.allow(["reddit:post:t3_a"], account: account)
    check(store.records(now: now).isEmpty, "Unhide resurrected stale cached text")
    try store.ingest(data([post("a")]), account: account, now: now)
    check(store.records(now: now).count == 1, "Fresh post after unhide was rejected")
    subreddit["user_is_subscriber"] = true
    subreddit["name"] = "t5_test"
    try store.ingest(data([subreddit]), account: account, now: now)
    let communityIDs = store.canonicalIdentifiers(["t5_test"])
    check(communityIDs == ["reddit:subreddit:apple"], "Fullname community resolution failed")
    try store.suppress(communityIDs, account: account, now: now)
    let aliasReload = try ApolloContentCatalog(file: file)
    check(aliasReload.canonicalIdentifiers(["t5_test"]) == communityIDs, "Unsubscribe alias lost on restart")
    try store.ingest(data([subreddit]), account: account, now: now)
    check(store.records(kind: .subreddit, now: now).isEmpty, "Late listing resurrected unsubscribe")
    try store.allow(store.canonicalIdentifiers(["t5_test"]), account: account)
    try store.ingest(data([subreddit]), account: account, now: now)
    check(store.records(kind: .subreddit, now: now).count == 1, "Resubscribe did not allow fresh metadata")
    try store.configure(enabled: true, account: "other-account")
    check(store.state.suppressed == nil && store.state.suppressedAliases == nil, "Account change retained tombstones")

    // Reproduce the device's spoken community name. Include a newer community
    // whose description matches, so the intended name wins before applying limit.
    let names = try ApolloContentCatalog(file: directory.appendingPathComponent("names.json"), retention: 100)
    try names.configure(enabled: true, account: account)
    func community(_ name: String, description: String = "") -> [String: Any] {
        ["kind": "t5", "display_name": name, "public_description": description,
         "subreddit_type": "public", "over18": false, "user_is_subscriber": true]
    }
    try names.ingest(data([community("boutiquebluray"), community("boutique_bluray")]), account: account, now: now)
    try names.ingest(data([community("movies", description: "boutique blu-ray boutiqueBluray cinema")]),
                     account: account, now: now.addingTimeInterval(1))
    for query in ["boutique blu-ray", "BOUTIQUE BLU–RAY", "r/boutiquebluray", " /r/BoutiqueBluray "] {
        check(names.records(kind: .subreddit, query: query, limit: 1, now: now).map(\.id) == ["reddit:subreddit:boutiquebluray"],
              "Spoken/qualified name didn't outrank description: \(query)")
    }
    check(names.records(kind: .subreddit, query: "boutique_bluray", now: now).map(\.id) == ["reddit:subreddit:boutique_bluray"],
          "Underscore community name was conflated")
    check(names.records(kind: .subreddit, query: "cinema", now: now).map(\.id) == ["reddit:subreddit:movies"],
          "Description search regressed")
    check(names.records(kind: .subreddit, query: "boutique bluray missing", now: now).isEmpty,
          "Unmatched words were discarded")
    check(names.records(kind: .subreddit, query: "boutique blu-ray", now: now.addingTimeInterval(102)).isEmpty,
          "Spoken matching resurrected expired records")
    // A community's display title is its spoken alias ("Criterion Collection"
    // for r/criterion); a legacy snapshot without the field still decodes.
    var titled = community("criterion")
    titled["title"] = "The Criterion Collection"
    try names.ingest(data([titled]), account: account, now: now)
    check(names.records(kind: .subreddit, query: "the criterion collection", limit: 1, now: now).map(\.id) == ["reddit:subreddit:criterion"],
          "Community display title was not a spoken alias")
    check(names.resolve(["reddit:subreddit:criterion"], now: now).first?.displayTitle == "The Criterion Collection",
          "Community display title was not stored")
    let legacy = try JSONDecoder().decode(ApolloContentRecord.self, from: Data(#"{"id":"reddit:subreddit:x","kind":"subreddit","title":"r/x","subreddit":"x","author":"","text":"","createdAt":0,"observedAt":0,"route":"apollo://reddit.com/r/x/"}"#.utf8))
    check(legacy.displayTitle == nil, "Legacy record without display title failed to decode")
    check(ApolloContentRecord.webURL(forRoute: "apollo://reddit.com/r/apple/comments/abc123/").absoluteString
              == "https://www.reddit.com/r/apple/comments/abc123/", "Post share URL was not the HTTPS permalink")
    check(ApolloContentRecord.webURL(forRoute: "https://evil.example/x").absoluteString == "https://www.reddit.com/",
          "Share URL escaped reddit.com")
    try names.suppress(["reddit:subreddit:boutiquebluray"], account: account, now: now)
    check(!names.records(kind: .subreddit, query: "boutique blu-ray", now: now).contains { $0.id == "reddit:subreddit:boutiquebluray" },
          "Spoken matching resurrected a suppressed community")
    try names.configure(enabled: false, account: account)
    check(names.records(kind: .subreddit, query: "boutique blu-ray", now: now).isEmpty,
          "Spoken matching bypassed opt-out")
    // Listing metadata Siri can answer from, with legacy/self-post handling.
    let meta = try ApolloContentCatalog(file: directory.appendingPathComponent("meta.json"))
    try meta.configure(enabled: true, account: account)
    try meta.ingest(data([["kind": "t3", "name": "t3_meta1", "title": "Link", "subreddit": "apple", "author": "a",
                           "selftext": "", "subreddit_type": "public", "over_18": false, "hidden": false,
                           "score": 1234, "num_comments": 56, "domain": "TheVerge.com"],
                          ["kind": "t3", "name": "t3_meta2", "title": "Self", "subreddit": "apple", "author": "a",
                           "selftext": "x", "subreddit_type": "public", "over_18": false, "hidden": false,
                           "domain": "self.apple"]]), account: account, now: now)
    let link = meta.resolve(["reddit:post:t3_meta1"], now: now).first
    check(link?.score == 1234 && link?.commentCount == 56 && link?.linkDomain == "theverge.com", "Post metadata not captured")
    let selfPost = meta.resolve(["reddit:post:t3_meta2"], now: now).first
    check(selfPost?.linkDomain == nil && selfPost?.score == nil, "Self-post domain or absent score was stored")
    check(!meta.isSuppressed("reddit:post:t3_meta1"), "Unsuppressed post reported as suppressed")
    try meta.suppress(["reddit:post:t3_meta1"], account: account, now: now)
    check(meta.isSuppressed("reddit:post:t3_meta1"), "Suppressed post not reported")

    // Session context: viewed posts and loaded comments, memory-only.
    func comment(_ id: String, link: String = "t3_meta1", body: String = "A useful comment body", score: Int = 1,
                 depth: Int = 0, op: Bool = false, author: String = "someone") -> [String: Any] {
        ["name": id, "link_id": link, "subreddit": "apple", "author": author, "body": body,
         "score": score, "depth": depth, "is_submitter": op, "created_utc": 1_700_000_000]
    }
    check(ApolloCommentRecord.parse(comment("t1_ok"), order: 0)?.postID == "reddit:post:t3_meta1", "Comment did not parse")
    check(ApolloCommentRecord.parse(comment("t1_ok", link: "meta1"), order: 0)?.postID == "reddit:post:t3_meta1",
          "Unprefixed link id not normalized")
    check(ApolloCommentRecord.parse(comment("t1_x", body: "[removed]"), order: 0) == nil, "Removed comment accepted")
    check(ApolloCommentRecord.parse(comment("t1_x", author: "[deleted]"), order: 0) == nil, "Deleted author accepted")
    check(ApolloCommentRecord.parse(comment("t3_notacomment"), order: 0) == nil, "Non-comment fullname accepted")
    check(ApolloCommentRecord.parse(comment("t1_abc"), order: 0)?.route == "apollo://reddit.com/r/apple/comments/meta1/_/abc/",
          "Comment route incorrect")

    let session = ApolloSessionContext(postLimit: 2, threadLimit: 2, commentsPerThread: 3)
    session.configure(account: account)
    let parsed = [comment("t1_low", score: 1), comment("t1_top", score: 900), comment("t1_op", score: 2, op: true),
                  comment("t1_deep", score: 950, depth: 12), comment("t1_over", score: 5000)]
        .enumerated().compactMap { ApolloCommentRecord.parse($0.element, order: $0.offset) }
    session.observe(comments: parsed, account: account)
    check(session.comments(forPost: "reddit:post:t3_meta1", limit: 10).count == 3, "Per-thread comment cap ignored")
    check(session.comments(forPost: "reddit:post:t3_meta1", limit: 2).map(\.id) == ["reddit:comment:t1_op", "reddit:comment:t1_top"],
          "Comment ranking should favour OP and score")
    check(session.comments(["reddit:comment:t1_top"]).first?.score == 900, "Comment resolve failed")
    check(session.search("useful", limit: 5).count == 3, "Comment search failed")
    session.observe(comments: parsed, account: "other-account")
    check(session.comments(forPost: "reddit:post:t3_meta1", limit: 10).count == 3, "Wrong-account comments accepted")
    for id in ["t1_a2", "t1_a3"] {
        session.observe(comments: [ApolloCommentRecord.parse(comment(id, link: "t3_\(id.dropFirst(3))"), order: 0)!], account: account)
    }
    check(session.comments(forPost: "reddit:post:t3_meta1", limit: 10).isEmpty, "Oldest comment thread not evicted")
    let viewed = ["t3_v1", "t3_v2", "t3_v3"].compactMap {
        ApolloContentRecord.parse(["kind": "t3", "name": $0, "title": "T", "subreddit": "apple", "author": "a",
                                   "selftext": "", "subreddit_type": "public", "over_18": false, "hidden": false], now: now)
    }
    viewed.forEach { session.observe(post: $0, account: account) }
    check(session.post("reddit:post:t3_v1") == nil && session.post("reddit:post:t3_v3") != nil, "Viewed-post cap not LRU")
    session.suppress(["reddit:post:t3_v3", "reddit:post:t3_a3"])
    check(session.post("reddit:post:t3_v3") == nil && session.comments(forPost: "reddit:post:t3_a3", limit: 5).isEmpty,
          "Suppression kept session content")
    session.configure(account: nil)
    check(session.post("reddit:post:t3_v2") == nil && session.comments(forPost: "reddit:post:t3_a2", limit: 5).isEmpty,
          "Scope change kept session content")
    print("PASS: \(assertions) catalogue assertions (persistence, privacy, account isolation, search, retention, routing)")
} catch {
    fatalError("Catalogue test failed: \(error)")
}
