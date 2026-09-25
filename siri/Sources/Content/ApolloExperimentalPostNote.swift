import AppIntents
import CoreSpotlight
import Foundation

/// Deliberate, opt-in schema experiment: a read-only text projection of a
/// public Reddit post, not a claim that Apollo can create/edit/delete notes.
/// Shape verified against Xcode 27's AppIntentSchemas NoteEntity record.
@AppEntity(schema: .notes.note)
struct ApolloExperimentalPostNote: IndexedEntity {
    static let defaultQuery = ApolloExperimentalPostNoteQuery()
    let id: String
    var name: AttributedString
    var content: AttributedString?
    var attachments: [IntentFile]
    var isPinned: Bool
    var creationDate: Date?
    var modificationDate: Date?
    var folder: ApolloExperimentalPostFolder?

    static let prefix = "experimental:note:"
    init(_ record: ApolloContentRecord) {
        id = Self.prefix + record.id
        name = AttributedString(record.title)
        content = AttributedString("r/\(record.subreddit) · u/\(record.author)\n\(record.text)")
        attachments = []
        isPinned = false
        creationDate = record.createdAt
        modificationDate = nil // Observation time is not a Reddit edit time.
        folder = nil
    }
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(String(name.characters))", subtitle: "Apollo schema experiment")
    }
}
