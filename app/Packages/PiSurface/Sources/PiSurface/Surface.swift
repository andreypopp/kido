import SwiftUI

public struct Surface: View {
    @Bindable var session: Session
    @State private var draft = ComposerDraft()
    @State private var tailRequest = 0
    private let expanded: Bool
    public init(session: Session, expanded: Bool = false) { self.session = session; self.expanded = expanded }
    init(session: Session, draft: ComposerDraft) { self.session = session; self.expanded = false; self._draft = State(initialValue: draft) }
    private struct DialogIdentity: Identifiable {
        var id: String
        var value: JSON
    }
    public var body: some View {
        VStack(spacing: 0) {
            TranscriptView(session: session, expanded: expanded, tailRequest: tailRequest)
            Divider()
            ComposerView(session: session, draft: draft, tailRequest: $tailRequest)

        }.background(Color(nsColor: .windowBackgroundColor))
            .sheet(item: Binding<DialogIdentity?>(get: {
                guard session.synchronized, let dialog = session.dialogs.first else { return nil }
                return DialogIdentity(id: session.scope + ":" + dialog["id"].string, value: dialog)
            }, set: { _ in })) { item in DialogView(session: session, dialog: item.value).id(item.id).interactiveDismissDisabled() }
    }
}
