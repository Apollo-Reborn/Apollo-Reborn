import SwiftUI

struct ApolloProofSnippetView: View {
    let subreddit: ApolloProofSubredditEntity

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(subreddit.name, systemImage: "bubble.left.and.bubble.right")
                .font(.headline)
            Text(subreddit.summary)
                .font(.body)
            Text("Apollo Reborn")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .accessibilityElement(children: .combine)
    }
}
