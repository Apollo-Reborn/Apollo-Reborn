import AppIntents
import CoreSpotlight
import Foundation

/// A deliberately bounded catalogue: no account credentials, network requests,
/// subscriptions, or browsing history are read by this packaging proof.
public struct ApolloProofSubredditEntity: IndexedEntity {
    public static let typeDisplayRepresentation: TypeDisplayRepresentation = "Subreddit"
    public static let defaultQuery = ApolloProofSubredditQuery()

    public let id: String
    @Property(title: "Name") public var name: String
    @Property(title: "Description") public var summary: String

    public static var community: Self {
        Self(id: "reddit:subreddit:apolloreborn", name: "r/ApolloReborn",
             summary: "The community for Apollo Reborn.")
    }

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(summary)",
                              image: .init(systemName: "bubble.left.and.bubble.right"))
    }

    public var attributeSet: CSSearchableItemAttributeSet {
        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        attributes.title = name
        attributes.contentDescription = summary
        attributes.keywords = ["Apollo", "Apollo Reborn", "subreddit"]
        return attributes
    }

    private init(id: String, name: String, summary: String) {
        self.id = id
        self.name = name
        self.summary = summary
    }
}
