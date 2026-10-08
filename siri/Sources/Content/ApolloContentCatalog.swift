import Foundation

/// Foundation-only storage shared by the app integration and host-side tests.
/// Core Spotlight is a projection, not the only copy of a post's searchable text.
struct ApolloContentRecord: Codable, Sendable, Equatable, Identifiable {
    enum Kind: String, Codable, Sendable { case post, subreddit }
    let id: String
    let kind: Kind
    let title: String
    let subreddit: String
    let author: String
    let text: String
    let createdAt: Date
    var observedAt: Date
    let route: String
    let fullName: String?
    /// Community display title (Reddit's t5 `title`, e.g. "Boutique Blu-ray").
    /// Siri transcribes spoken names as words, so this is the natural alias for
    /// a joined `display_name`. Optional so older catalogue snapshots decode.
    var displayTitle: String? = nil
    /// Post-only listing metadata Siri can answer from ("how many comments").
    /// Optional so older snapshots decode; nil when Reddit omitted the field.
    var score: Int? = nil
    var commentCount: Int? = nil
    /// Outbound link host for link posts (e.g. "theverge.com"); nil for self posts.
    var linkDomain: String? = nil

    /// Public HTTPS equivalent of a validated native route, for sharing.
    /// Routes are only ever built by `parse` from validated names.
    static func webURL(forRoute route: String) -> URL {
        let path = route.hasPrefix("apollo://reddit.com") ? String(route.dropFirst("apollo://reddit.com".count)) : "/"
        return URL(string: "https://www.reddit.com" + path) ?? URL(string: "https://www.reddit.com/")!
    }

    static func identifier(_ json: [String: Any]) -> String? {
        if json["kind"] as? String == "t3", let name = json["name"] as? String,
           name.hasPrefix("t3_"), validName(String(name.dropFirst(3))) {
            return "reddit:post:\(name.lowercased())"
        }
        if json["kind"] as? String == "t5", let name = json["display_name"] as? String, validName(name) {
            return "reddit:subreddit:\(name.lowercased())"
        }
        return nil
    }

    /// Hostname only; self posts ("self.apple") and anything malformed are dropped.
    private static func linkDomain(_ value: String?) -> String? {
        guard let value = value?.lowercased(), !value.hasPrefix("self."), (1...253).contains(value.count),
              value.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-" })
        else { return nil }
        return value
    }

    static func validName(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 64 && value.unicodeScalars.allSatisfy {
            (65...90).contains($0.value) || (97...122).contains($0.value) ||
            (48...57).contains($0.value) || $0.value == 95
        }
    }

    static func parse(_ json: [String: Any], now: Date) -> Self? {
        // Reddit uses different NSFW keys for post (t3) and community (t5)
        // records. Require the appropriate flag; missing is not equivalent to safe.
        let isPost = json["kind"] as? String == "t3"
        guard let id = identifier(json), json["subreddit_type"] as? String == "public",
              let over18 = json[isPost ? "over_18" : "over18"] as? Bool, !over18 else { return nil }
        let subreddit = json[isPost ? "subreddit" : "display_name"] as? String ?? ""
        guard validName(subreddit) else { return nil }
        let title = json["title"] as? String ?? ""
        let text = json[isPost ? "selftext" : "public_description"] as? String ?? ""
        let author = isPost ? json["author"] as? String ?? "" : ""
        if isPost {
            guard let hidden = json["hidden"] as? Bool, !hidden,
                  !title.isEmpty, author != "[deleted]", text != "[removed]", text != "[deleted]",
                  (json["removed_by_category"] as? String ?? "").isEmpty else { return nil }
        } else {
            // Search suggestions and arbitrary communities aren't subscriptions.
            guard json["user_is_subscriber"] as? Bool == true else { return nil }
        }
        // Derive the native route from validated identifiers, not an untrusted
        // outbound link. A malicious/link post can never route outside Apollo.
        let route: String
        if isPost {
            guard let name = json["name"] as? String else { return nil }
            route = "apollo://reddit.com/r/\(subreddit)/comments/\(name.dropFirst(3))/"
        } else {
            route = "apollo://reddit.com/r/\(subreddit)/"
        }
        let timestamp = (json["created_utc"] as? NSNumber)?.doubleValue ?? now.timeIntervalSince1970
        guard timestamp.isFinite else { return nil }
        let communityTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self(id: id, kind: isPost ? .post : .subreddit,
                    title: String((isPost ? title : "r/\(subreddit)").prefix(512)),
                    subreddit: subreddit, author: String(author.prefix(64)),
                    text: String(text.prefix(2048)), createdAt: Date(timeIntervalSince1970: timestamp),
                    observedAt: now, route: route, fullName: json["name"] as? String,
                    displayTitle: isPost || communityTitle.isEmpty ? nil : String(communityTitle.prefix(128)),
                    score: isPost ? (json["score"] as? NSNumber)?.intValue : nil,
                    commentCount: isPost ? (json["num_comments"] as? NSNumber)?.intValue : nil,
                    linkDomain: isPost ? linkDomain(json["domain"] as? String) : nil)
    }
}

/// Access only from the content-service actor (or a single-threaded host test).
/// Atomic snapshots are deliberately simple at this bounded first-milestone
/// size. A future SQLite migration can preserve the same record/entity IDs.
final class ApolloContentCatalog {
    struct State: Codable {
        var version = 1
        var enabled = false
        var account: String? // One-way account fingerprint; never credentials.
        var records: [String: ApolloContentRecord] = [:]
        // Optional for decoding the first v1 snapshots without a migration.
        // Tombstones stop older in-flight listings from resurrecting a hide.
        var suppressed: [String: Date]? = nil
        var suppressedAliases: [String: String]? = nil
    }
    enum Failure: Error { case unsupportedVersion, oversizedFile, invalidPayload }
    private(set) var state: State
    private let file: URL
    let postLimit: Int
    let subredditLimit: Int
    let retention: TimeInterval

    init(file: URL, postLimit: Int = 1000, subredditLimit: Int = 500,
         retention: TimeInterval = 30 * 24 * 60 * 60) throws {
        self.file = file
        self.postLimit = max(0, postLimit)
        self.subredditLimit = max(0, subredditLimit)
        self.retention = retention
        if FileManager.default.fileExists(atPath: file.path) {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            guard (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 8 * 1024 * 1024 else {
                throw Failure.oversizedFile
            }
            state = try JSONDecoder().decode(State.self, from: Data(contentsOf: file))
            guard state.version == 1 else { throw Failure.unsupportedVersion }
        } else {
            state = State()
        }
    }

    /// Clears the previous account before any new records can be resolved.
    @discardableResult
    func configure(enabled: Bool, account: String?) throws -> Bool {
        let changedScope = state.account != account || state.enabled != enabled
        guard changedScope else { return false }
        var next = state
        next.enabled = enabled
        next.account = account
        next.records.removeAll()
        next.suppressed = nil
        next.suppressedAliases = nil
        try commit(next)
        return true
    }

    func ingest(_ data: Data, account: String, now: Date = Date()) throws {
        guard state.enabled, state.account == account else { return }
        guard data.count <= 2 * 1024 * 1024,
              let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              rows.count <= 500 else { throw Failure.invalidPayload }
        var next = state
        for row in rows {
            guard let id = ApolloContentRecord.identifier(row) else { continue }
            guard next.suppressed?[id] == nil else { continue }
            // Also delete a previously eligible record that becomes hidden,
            // NSFW, private, removed, or an unsubscribed community.
            next.records[id] = ApolloContentRecord.parse(row, now: now)
        }
        prune(&next, now: now)
        try commit(next)
    }

    func expire(now: Date = Date()) throws {
        var next = state
        prune(&next, now: now)
        if next.records != state.records || next.suppressed != state.suppressed { try commit(next) }
    }

    func suppress(_ identifiers: [String], account: String, now: Date = Date()) throws {
        guard state.enabled, state.account == account else { return }
        var next = state
        var suppressed = next.suppressed ?? [:]
        for id in identifiers.prefix(2000) {
            guard id.hasPrefix("reddit:post:t3_") || id.hasPrefix("reddit:subreddit:") else { continue }
            guard id.utf8.count <= 100 else { continue }
            suppressed[id] = now
            if let record = next.records[id], record.kind == .subreddit, let fullName = record.fullName {
                if next.suppressedAliases == nil { next.suppressedAliases = [:] }
                next.suppressedAliases?[fullName.lowercased()] = id
            }
            next.records.removeValue(forKey: id)
        }
        next.suppressed = suppressed
        prune(&next, now: now)
        try commit(next)
    }

    func allow(_ identifiers: [String], account: String) throws {
        guard state.enabled, state.account == account else { return }
        var next = state
        for id in identifiers.prefix(2000) { next.suppressed?.removeValue(forKey: id) }
        next.suppressedAliases = next.suppressedAliases?.filter { next.suppressed?[$0.value] != nil }
        // Never resurrect cached text here. A fresh eligible listing is required.
        try commit(next)
    }

    func isSuppressed(_ id: String) -> Bool { state.suppressed?[id] != nil }

    func canonicalIdentifiers(_ nativeIdentifiers: [String]) -> [String] {
        nativeIdentifiers.prefix(2000).compactMap { raw in
            let name = raw.lowercased()
            if name.hasPrefix("t3_") {
                return ApolloContentRecord.identifier(["kind": "t3", "name": name])
            }
            if name.hasPrefix("r/") {
                return ApolloContentRecord.identifier(["kind": "t5", "display_name": String(name.dropFirst(2))])
            }
            if name.hasPrefix("t5_") {
                return state.records.values.first { $0.kind == .subreddit && $0.fullName?.lowercased() == name }?.id
                    ?? state.suppressedAliases?[name]
            }
            return nil
        }
    }

    func records(kind: ApolloContentRecord.Kind? = nil, query: String = "", limit: Int = 100,
                 now: Date = Date()) -> [ApolloContentRecord] {
        guard state.enabled, state.account != nil, limit > 0 else { return [] }
        let terms = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: \.isWhitespace).map(String.init)
        let eligible = state.records.values.filter {
            now.timeIntervalSince($0.observedAt) < retention && (kind == nil || $0.kind == kind)
        }
        var matches: [ApolloContentRecord] = []
        if kind == .subreddit, !terms.isEmpty {
            // Siri may transcribe a joined community name as separate words or
            // insert a hyphen ("boutique blu-ray"). Match the whole name before
            // searching descriptions; don't let a description match displace an
            // exact destination. Keep underscores meaningful and return every
            // match rather than arbitrarily selecting an ambiguous destination.
            let name = Self.spokenSubredditName(query)
            if !name.isEmpty {
                matches = eligible.filter {
                    Self.spokenSubredditName($0.subreddit) == name
                        || $0.displayTitle.map(Self.spokenSubredditName) == name
                }
            }
        }
        if matches.isEmpty {
            matches = eligible.filter { record in
                let haystack = "\(record.title) \(record.displayTitle ?? "") \(record.subreddit) \(record.author) \(record.text)"
                    .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                return terms.allSatisfy { haystack.contains($0) }
            }
        }
        return matches.sorted {
            $0.observedAt == $1.observedAt ? $0.id < $1.id : $0.observedAt > $1.observedAt
        }.prefix(limit).map { $0 }
    }

    private static func spokenSubredditName(_ value: String) -> String {
        var name = value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasPrefix("/r/") { name.removeFirst(3) }
        else if name.hasPrefix("r/") { name.removeFirst(2) }
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-‐‑‒–—"))
        return String(name.unicodeScalars.filter { !separators.contains($0) })
    }

    func resolve(_ identifiers: [String], now: Date = Date()) -> [ApolloContentRecord] {
        guard state.enabled, state.account != nil else { return [] }
        return identifiers.compactMap { state.records[$0] }.filter { now.timeIntervalSince($0.observedAt) < retention }
    }

    private func prune(_ next: inout State, now: Date) {
        let recent = (next.suppressed ?? [:]).filter { now.timeIntervalSince($0.value) < retention }
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
        next.suppressed = Dictionary(uniqueKeysWithValues: recent.prefix(2000).map { ($0.key, $0.value) })
        next.suppressedAliases = next.suppressedAliases?.filter { next.suppressed?[$0.value] != nil }
        next.records = next.records.filter { now.timeIntervalSince($0.value.observedAt) < retention }
        for (kind, limit) in [(ApolloContentRecord.Kind.post, postLimit), (.subreddit, subredditLimit)] {
            let sorted = next.records.values.filter { $0.kind == kind }.sorted {
                $0.observedAt == $1.observedAt ? $0.id < $1.id : $0.observedAt > $1.observedAt
            }
            for record in sorted.dropFirst(limit) { next.records.removeValue(forKey: record.id) }
        }
    }

    private func commit(_ next: State) throws {
        let directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var protectedDirectory = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try protectedDirectory.setResourceValues(values)
        let data = try JSONEncoder().encode(next)
        guard data.count <= 8 * 1024 * 1024 else { throw Failure.oversizedFile }
        #if os(iOS)
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: file, options: .atomic)
        #endif
        state = next // Don't acknowledge a write which didn't reach disk.
    }
}
