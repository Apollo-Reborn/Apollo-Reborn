import AppIntents
import SwiftUI

struct ApolloPostResultRow: View {
    let post: ApolloPostEntity

    var body: some View {
        Button(intent: OpenApolloPostIntent(target: post)) {
            VStack(alignment: .leading, spacing: 4) {
                Text(post.title).font(.body).fontWeight(.semibold).lineLimit(3)
                Text("r/\(post.subreddit) · u/\(post.author)", bundle: #bundle)
                    .font(.caption).foregroundStyle(.secondary)
                if !post.text.isEmpty {
                    Text(post.text).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text("Opens this post in Apollo", bundle: #bundle))
    }
}
