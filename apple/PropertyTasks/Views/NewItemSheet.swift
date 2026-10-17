import PropertyTasksCore
import SwiftUI

struct NewItemSheet: View {
    let store: SpaceStore
    let parentId: String?
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var kind: Kind = .task
    @State private var priority: Priority = .normal

    var body: some View {
        NavigationStack {
            Form {
                TextField("Title", text: $title)
                Picker("Kind", selection: $kind) {
                    Text("Task").tag(Kind.task); Text("Place").tag(Kind.container); Text("Note").tag(Kind.note)
                }
                .pickerStyle(.segmented)
                if kind == .task {
                    Picker("Priority", selection: $priority) { ForEach(Priority.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }
                }
                if let parentId, let parent = store.store.getNode(parentId) {
                    LabeledContent("Inside", value: parent.title)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("New item")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { Task { await add() } }.disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 360, minHeight: 260)
        #endif
    }

    private func add() async {
        let payload = NodeCreatedPayload(parentId: parentId, kind: kind, title: title.trimmingCharacters(in: .whitespaces),
                                         priority: kind == .task ? priority : .none, body: kind == .note ? "" : nil)
        if await store.submit(.nodeCreated(payload), nodeId: uuidv7()) { dismiss() }
    }
}
