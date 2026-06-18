import SwiftUI

@main
struct PhosphorApp: App {
    var body: some Scene {
        DocumentGroup { document in
            PhosphorDocumentView(document: document)
        } makeDocument: { configuration, _ in
            PhosphorMetalDocument(configuration: configuration)
        }
    }
}
