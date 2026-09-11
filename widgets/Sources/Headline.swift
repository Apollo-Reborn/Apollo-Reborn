import WidgetKit
import SwiftUI

// MARK: - Headline (Lock Screen only)

/// A Lock-Screen headline: the top post title from one chosen subreddit, rotating
/// through the current top posts. Text-only (accessory slots can't show images),
/// so it's cheap to build and safe for the tight accessory reload budget.
struct HeadlineProvider: IntentTimelineProvider {
    typealias Entry = WidgetEntry
    typealias Intent = HeadlineConfigurationIntent

    func placeholder(in context: Context) -> WidgetEntry { .sample([WidgetSample.feed[0]]) }

    func getSnapshot(for configuration: Intent, in context: Context,
                     completion: @escaping (WidgetEntry) -> Void) {
        if context.isPreview { completion(.sample([WidgetSample.feed[0]])); return }
        let account = widgetAccountKey(configuration.setupCode)
        let source = Self.source(configuration, ownMultis: OwnMultis.names(for: account))
        let post = PostCache.load("headline.\(source.cacheKey(account: account))").first ?? WidgetSample.feed[0]
        completion(WidgetEntry(date: Date(), state: .posts([RenderPost(post: post, imageData: nil)])))
    }

    private static func source(_ configuration: Intent, ownMultis: Set<String>) -> FeedSource {
        widgetSource(text: configuration.subreddit, default: .subreddits(["worldnews"]), ownMultis: ownMultis)
    }

    func getTimeline(for configuration: Intent, in context: Context,
                     completion: @escaping (Timeline<WidgetEntry>) -> Void) {
        let account = widgetAccountKey(configuration.setupCode)
        rwLog.log("getTimeline Headline family=\(familyName(context.family), privacy: .public)")
        runSourceTimeline(
            code: configuration.setupCode,
            resolve: { Self.source(configuration, ownMultis: $0) },
            cacheKey: { "headline.\($0.cacheKey(account: account))" },
            sort: .hot, limit: 10,
            assemble: { posts, _, key in assembleText(posts, key: key) },   // rotates through the top posts
            completion: completion)
    }
}

/// Lock-Screen rendering — reuses the shared accessory post view, labelled with
/// the post's subreddit. Tapping opens the post in Apollo.
struct HeadlineWidgetView: View {
    let entry: WidgetEntry
    var body: some View {
        let sub = firstPost(entry)?.subreddit ?? ""
        AccessoryPostView(entry: entry, label: sub.isEmpty ? "Reddit" : "r/\(sub)", icon: "newspaper")
    }
}
