import AppIntentsTesting
import XCTest

/// Tests resolve definitions from the installed Apollo, never link ApolloSiri
/// into this process. Execution also requires a working AppIntentsTesting
/// service; see README.md for the Xcode 27 simulator entitlement blocker.
final class ApolloSiriTests: XCTestCase {
    private var definitions: IntentDefinitions {
        IntentDefinitions(bundleIdentifier: "com.christianselig.Apollo")
    }

    func testInstalledApolloResolvesOnlyTheFixedSubreddit() async throws {
        let query = definitions.entities["ApolloProofSubredditEntity"]
        let matches = try await query.entities(matching: "ApolloReborn")
        XCTAssertEqual(matches.count, 1)
        let subreddit = try XCTUnwrap(matches.first)
        XCTAssertEqual(subreddit.identifier.instanceIdentifier, "reddit:subreddit:apolloreborn")
        let name: String = try subreddit.name
        XCTAssertEqual(name, "r/ApolloReborn")
        let missing = try await query.entities(matching: "does-not-exist-in-this-proof")
        XCTAssertTrue(missing.isEmpty)
    }

    func testInstalledApolloReturnsCommunityAndIndexesIt() async throws {
        // Run twice: the second execution must resolve the same entity and must
        // not produce duplicates in Spotlight. The caller can terminate Apollo
        // before starting the suite to exercise system-driven cold launch too.
        for _ in 0..<2 {
            let result = try await definitions.intents["ShowApolloSiriProofIntent"].makeIntent().run()
            let name: String = try result.value.name
            XCTAssertEqual(name, "r/ApolloReborn")
        }
        let query = definitions.entities["ApolloProofSubredditEntity"]
        for _ in 0..<30 {
            let matches = try await query.spotlightQuery("ApolloReborn")
            if !matches.isEmpty {
                XCTAssertEqual(matches.count, 1)
                return
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTFail("Apollo did not expose the fixed subreddit in Spotlight within six seconds.")
    }
}
