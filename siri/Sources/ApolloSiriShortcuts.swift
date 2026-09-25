import AppIntents

public struct ApolloSiriShortcuts: AppShortcutsProvider {
    // Publish an empty catalogue while testing schema-based Siri discovery.
    // Keep the provider identity so launch-time refresh advertises the removal
    // of the previous five phrase shortcuts. The AppIntent types remain intact
    // for schema invocation, snippets, and existing user-authored workflows.
    public static var appShortcuts: [AppShortcut] {
        return []
    }
}
