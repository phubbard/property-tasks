import PropertyTasksCore
import SwiftUI

struct RootView: View {
    @Environment(Session.self) private var session
    @State private var spaces: [SyncClient.SpaceSummary] = []
    @State private var selection: String?
    @State private var stores: [String: SpaceStore] = [:]
    @State private var error: String?
    @State private var showingSettings = false
    @State private var newTitle = ""
    @State private var creating = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(spaces) { s in
                    Label(s.title, systemImage: "house").tag(s.id)
                }
            }
            .navigationTitle("Spaces")
            .overlay {
                if spaces.isEmpty {
                    ContentUnavailableView(error == nil ? "No Spaces yet" : "Can't reach the server",
                                           systemImage: error == nil ? "house" : "wifi.exclamationmark",
                                           description: Text(error ?? "Create one with the + button."))
                }
            }
            .toolbar {
                ToolbarItem { Button("Settings", systemImage: "gear") { showingSettings = true } }
                ToolbarItem { Button("New Space", systemImage: "plus") { creating = true } }
                ToolbarItem { Button("Refresh", systemImage: "arrow.clockwise") { Task { await loadSpaces() } } }
            }
            .alert("New Space", isPresented: $creating) {
                TextField("Title", text: $newTitle)
                Button("Create") { Task { await create() } }
                Button("Cancel", role: .cancel) {}
            }
            .sheet(isPresented: $showingSettings) { SettingsView() }
        } detail: {
            if let id = selection, let store = storeFor(id) {
                SpaceView(store: store)
            } else {
                ContentUnavailableView("Pick a Space", systemImage: "sidebar.left")
            }
        }
        .task(id: session.serverURL + session.devUser) { stores = [:]; await loadSpaces() }
    }

    private func storeFor(_ id: String) -> SpaceStore? {
        if let s = stores[id] { return s }
        guard let summary = spaces.first(where: { $0.id == id }) else { return nil }
        let s = SpaceStore(spaceId: id, title: summary.title, client: session.client, actorId: session.devUser, deviceId: session.deviceId)
        stores[id] = s
        Task { await s.load() }
        return s
    }

    private func loadSpaces() async {
        do {
            spaces = try await session.client.listSpaces()
            error = nil
            if selection == nil { selection = spaces.first?.id }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func create() async {
        let title = newTitle.trimmingCharacters(in: .whitespaces)
        newTitle = ""
        guard !title.isEmpty else { return }
        do {
            let id = try await session.client.createSpace(title: title)
            await loadSpaces()
            selection = id
        } catch {
            self.error = error.localizedDescription
        }
    }
}
