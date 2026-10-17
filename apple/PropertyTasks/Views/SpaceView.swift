import PropertyTasksCore
import SwiftUI

struct SpaceView: View {
    let store: SpaceStore
    enum Mode: String, CaseIterable { case tree = "Tree", list = "List" }
    @State private var mode: Mode = .tree
    @State private var filter = Filter()
    @State private var search = ""
    @State private var creating = false
    @State private var capturing = false

    private var now: Millis { Millis(Date().timeIntervalSince1970 * 1000) }

    var body: some View {
        NavigationStack {
            Group {
                let _ = store.version
                var f = filter
                let _ = { f.text = search.isEmpty ? nil : search }()
                switch mode {
                case .tree:
                    List(tree(store.store, f, now: now)) { row in
                        NavigationLink(value: row.node.id) {
                            NodeRow(store: store, node: row.node, path: nil)
                                .padding(.leading, CGFloat(row.depth) * 16)
                                .opacity(row.dimmed ? 0.45 : 1)
                        }
                    }
                case .list:
                    List(query(store.store, f, now: now)) { node in
                        NavigationLink(value: node.id) {
                            NodeRow(store: store, node: node, path: store.path(for: node.id))
                        }
                    }
                }
            }
            .navigationTitle(store.title)
            .navigationDestination(for: String.self) { id in NodeView(store: store, nodeId: id) }
            .searchable(text: $search)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("View", selection: $mode) { ForEach(Mode.allCases, id: \.self) { Text($0.rawValue) } }
                        .pickerStyle(.segmented)
                }
                ToolbarItem { FilterMenu(filter: $filter) }
                ToolbarItem { Button("Refresh", systemImage: store.syncing ? "arrow.triangle.2.circlepath" : "arrow.clockwise") { Task { await store.refresh() } } }
                ToolbarItem { Button("New item", systemImage: "plus") { creating = true }.disabled(!store.canWrite) }
            }
            .sheet(isPresented: $creating) { NewItemSheet(store: store, parentId: nil) }
            #if os(iOS)
            .fullScreenCover(isPresented: $capturing) { CaptureSheet(store: store) }
            .safeAreaInset(edge: .bottom) {
                // The headline action (DESIGN.md §3): camera first, big enough to hit one-handed.
                Button { capturing = true } label: {
                    Label("Capture", systemImage: "camera.fill")
                        .font(.headline)
                        .padding(.horizontal, 24).padding(.vertical, 14)
                        .background(Color.accentColor, in: Capsule())
                        .foregroundStyle(.white)
                        .shadow(radius: 4, y: 2)
                }
                .disabled(!store.canWrite)
                .opacity(store.canWrite ? 1 : 0.4)
                .padding(.bottom, 8)
                .accessibilityHint("Take photos and create a new item")
            }
            #endif
            .overlay(alignment: .bottom) {
                if let e = store.lastError {
                    Text(e).font(.caption).padding(8).background(.red.opacity(0.85)).foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 8)).padding()
                        .onTapGesture { store.lastError = nil }
                }
            }
        }
    }
}

struct NodeRow: View {
    let store: SpaceStore
    let node: Node
    let path: String?

    var body: some View {
        let photos = store.store.getAttachmentsForNode(node.id).filter { $0.removedAt == nil && $0.kind == .image }.sorted { $0.sortKey < $1.sortKey }
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(node.title.isEmpty ? "(untitled)" : node.title)
                    .strikethrough(node.status == .done || node.status == .cancelled)
                if let path, !path.isEmpty { Text(path).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            if let first = photos.first {
                // Local derivative while the upload is pending, the Worker's thumb afterwards.
                BlobImage(store: store, sha256: first.sha256, variant: "thumb")
                    .frame(width: 36, height: 36).clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(alignment: .bottomTrailing) {
                        if store.isUploadPending(sha256: first.sha256) {
                            Image(systemName: "icloud.and.arrow.up").font(.system(size: 8)).padding(2)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                    }
                if photos.count > 1 { Text("+\(photos.count - 1)").font(.caption).foregroundStyle(.secondary) }
            }
            if node.kind == .container {
                let open = store.store.getChildren(node.id).filter { $0.kind == .task && $0.archivedAt == nil && ($0.status == .open || $0.status == .in_progress || $0.status == .blocked) }.count
                if open > 0 { Text("\(open)").font(.caption).monospacedDigit().padding(.horizontal, 6).background(.quaternary).clipShape(Capsule()) }
            }
            if node.priority >= .high { Image(systemName: node.priority == .urgent ? "exclamationmark.2" : "exclamationmark").foregroundStyle(.orange) }
        }
    }

    private var icon: String {
        switch node.kind {
        case .container: return "folder"
        case .task: return node.status == .done ? "checkmark.circle.fill" : node.status == .blocked ? "hand.raised" : "circle"
        case .note: return "note.text"
        }
    }
}

struct FilterMenu: View {
    @Binding var filter: Filter

    var body: some View {
        Menu("Filter", systemImage: filter == Filter() ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill") {
            Picker("Status", selection: Binding(
                get: { filter.status == nil ? "open" : filter.status!.isEmpty ? "all" : "done" },
                set: { v in filter.status = v == "open" ? nil : v == "all" ? [] : [.done, .cancelled] })) {
                Text("Open").tag("open"); Text("Done").tag("done"); Text("All").tag("all")
            }
            Picker("Priority", selection: Binding(get: { filter.priorityMin ?? .none }, set: { filter.priorityMin = $0 == .none ? nil : $0 })) {
                ForEach(Priority.allCases, id: \.self) { Text($0 == .none ? "Any priority" : "\($0.rawValue.capitalized) and up").tag($0) }
            }
            Picker("Kind", selection: Binding(get: { filter.kind?.first.map(\.rawValue) ?? "any" }, set: { filter.kind = $0 == "any" ? nil : [Kind(rawValue: $0)!] })) {
                Text("Any kind").tag("any"); Text("Tasks").tag("task"); Text("Places").tag("container"); Text("Notes").tag("note")
            }
            Toggle("Stale (30 days)", isOn: Binding(get: { filter.staleDays != nil }, set: { filter.staleDays = $0 ? 30 : nil }))
            Toggle("Has photos", isOn: Binding(get: { filter.has?.contains(.photos) ?? false }, set: { filter.has = $0 ? [.photos] : nil }))
            Toggle("Include archived", isOn: $filter.includeArchived)
            Button("Clear filters") { filter = Filter() }
        }
    }
}
