import AppIntents

public struct ApolloSiriShortcuts: AppShortcutsProvider {
    public static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ShowApolloSiriProofIntent(),
                    phrases: ["Show the community in \(.applicationName)"],
                    shortTitle: "Show Community", systemImageName: "bubble.left.and.bubble.right")
        AppShortcut(intent: OpenApolloProofSubredditIntent(target: .community),
                    phrases: ["Open the community in \(.applicationName)"],
                    shortTitle: "Open Community", systemImageName: "arrow.up.forward.app")
        AppShortcut(intent: SearchApolloProofIntent(),
                    phrases: ["Search \(.applicationName)"],
                    shortTitle: "Search", systemImageName: "magnifyingglass")
        AppShortcut(intent: FindApolloIndexedPostsIntent(),
                    phrases: ["Find indexed posts in \(.applicationName)"],
                    shortTitle: "Find Indexed Posts", systemImageName: "text.magnifyingglass")
        AppShortcut(intent: SearchApolloPostsIntent(),
                    phrases: ["Find posts in \(.applicationName)"],
                    shortTitle: "Search Posts", systemImageName: "text.bubble")
    }
}
