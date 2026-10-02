import AppIntents
import SwiftUI

struct ApolloPostResultsView: View {
    let posts: [ApolloPostEntity]
    let totalCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Posts from Apollo", bundle: #bundle).font(.headline)
            if posts.isEmpty {
                Text("No available posts. Enable content indexing and browse Apollo, or try another search.", bundle: #bundle)
                    .font(.body).foregroundStyle(.secondary)
            } else {
                ForEach(posts) { post in
                    ApolloPostResultRow(post: post)
                }
                if totalCount > posts.count {
                    Text("Showing \(posts.count) of \(totalCount) matches. All matches are included in the action’s output.", bundle: #bundle)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding()
    }
}
