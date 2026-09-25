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
                                    "subreddit_type": "public", "over_18": false, "user_is_subscriber": true]
    try store.ingest(data([subreddit]), account: account, now: now)
    check(store.records(now: now).first?.id == "reddit:subreddit:apple", "Community ID unstable")
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
    print("PASS: \(assertions) catalogue assertions (persistence, privacy, account isolation, search, retention, routing)")
} catch {
    fatalError("Catalogue test failed: \(error)")
}
