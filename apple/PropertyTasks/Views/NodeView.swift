import PhotosUI
import PropertyTasksCore
import SwiftUI

struct NodeView: View {
    let store: SpaceStore
    let nodeId: String
    @State private var title = ""
    @State private var newLabel = ""
    @State private var creatingChild = false
    @State private var pickerItem: PhotosPickerItem?
    @State private var uploading = false

    var body: some View {
        let _ = store.version
        if let node = store.store.getNode(nodeId) {
            Form {
                Section {
                    TextField("Title", text: $title)
                        .onSubmit { Task { await rename(node) } }
                    if node.kind == .task {
                        Picker("Status", selection: Binding(get: { node.status ?? .open }, set: { s in Task { await setStatus(node, s) } })) {
                            ForEach(Status.allCases, id: \.self) { Text($0.rawValue.replacingOccurrences(of: "_", with: " ").capitalized).tag($0) }
                        }
                    }
                    Picker("Priority", selection: Binding(get: { node.priority }, set: { p in Task { await setPriority(node, p) } })) {
                        ForEach(Priority.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }
                    LabeledContent("Where", value: store.path(for: node.id).isEmpty ? "Top level" : store.path(for: node.id))
                } header: { Text(node.kind.rawValue.capitalized) }

                Section("Labels") {
                    let labels = store.store.getLabels(node.id)
                    if !labels.isEmpty {
                        ScrollView(.horizontal) {
                            HStack {
                                ForEach(labels, id: \.self) { l in
                                    Text(l).padding(.horizontal, 8).padding(.vertical, 4).background(.quaternary).clipShape(Capsule())
                                        .contextMenu { Button("Remove", role: .destructive) { Task { await store.submit(.labelRemoved(LabelPayload(label: l)), nodeId: node.id) } } }
                                }
                            }
                        }
                    }
                    HStack {
                        TextField("Add label", text: $newLabel)
                        Button("Add") { Task { await addLabel(node) } }.disabled(newLabel.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }

                Section("Photos & files") {
                    let attachments = store.store.getAttachmentsForNode(node.id).filter { $0.removedAt == nil }
                    if !attachments.isEmpty {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96))], spacing: 8) {
                            ForEach(attachments) { a in
                                VStack(spacing: 2) {
                                    BlobImage(store: store, sha256: a.sha256, variant: "thumb")
                                        .frame(width: 96, height: 96).clipShape(RoundedRectangle(cornerRadius: 8))
                                    if !a.caption.isEmpty { Text(a.caption).font(.caption2).lineLimit(1) }
                                }
                                .contextMenu {
                                    Button("Remove", role: .destructive) { Task { await store.submit(.attachmentRemoved(AttachmentRefPayload(attachmentId: a.id)), nodeId: node.id) } }
                                }
                            }
                        }
                    }
                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        Label(uploading ? "Uploading…" : "Add photo", systemImage: "photo.badge.plus")
                    }
                    .disabled(uploading || !store.canWrite)
                }

                Section("Inside") {
                    let children = store.store.getChildren(node.id).filter { $0.archivedAt == nil }.sorted { $0.sortKey < $1.sortKey }
                    ForEach(children) { c in
                        NavigationLink(value: c.id) { NodeRow(store: store, node: c, path: nil) }
                    }
                    Button("Add inside", systemImage: "plus") { creatingChild = true }.disabled(!store.canWrite)
                }

                Section("History") {
                    ForEach(store.history(for: node.id)) { ev in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(describe(ev))
                            Text("\(store.displayName(ev.actorId)) · \(Date(timeIntervalSince1970: Double(ev.at) / 1000).formatted(date: .abbreviated, time: .shortened))\(ev.seq == nil ? " · not yet synced" : "")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    if node.archivedAt == nil {
                        Button("Archive", role: .destructive) { Task { await store.submit(.archived, nodeId: node.id) } }
                    } else {
                        Button("Restore") { Task { await store.submit(.restored, nodeId: node.id) } }
                    }
                }
                .disabled(!store.canWrite)
            }
            .formStyle(.grouped)
            .navigationTitle(node.title.isEmpty ? node.kind.rawValue.capitalized : node.title)
            .onAppear { title = node.title }
            .onChange(of: pickerItem) { _, item in if let item { Task { await attach(item, to: node) } } }
            .sheet(isPresented: $creatingChild) { NewItemSheet(store: store, parentId: node.id) }
        } else {
            ContentUnavailableView("Not found", systemImage: "questionmark.folder")
        }
    }

    private func rename(_ node: Node) async {
        let t = title.trimmingCharacters(in: .whitespaces)
        guard t != node.title else { return }
        await store.submit(.fieldChanged(FieldChangedPayload(field: "title", before: .string(node.title), after: .string(t))), nodeId: node.id)
    }
    private func setStatus(_ node: Node, _ s: Status) async {
        guard s != node.status else { return }
        await store.submit(.fieldChanged(FieldChangedPayload(field: "status", before: node.status.map { .string($0.rawValue) } ?? .null, after: .string(s.rawValue))), nodeId: node.id)
    }
    private func setPriority(_ node: Node, _ p: Priority) async {
        guard p != node.priority else { return }
        await store.submit(.fieldChanged(FieldChangedPayload(field: "priority", before: .string(node.priority.rawValue), after: .string(p.rawValue))), nodeId: node.id)
    }
    private func addLabel(_ node: Node) async {
        let l = newLabel.trimmingCharacters(in: .whitespaces)
        newLabel = ""
        guard !l.isEmpty else { return }
        await store.submit(.labelAdded(LabelPayload(label: l)), nodeId: node.id)
    }

    /// The photo flow (DESIGN.md §3, §11): hash, read EXIF into the capture sidecar, make the
    /// thumbnail and phone-sized derivatives here, upload all three, then record the event.
    private func attach(_ item: PhotosPickerItem, to node: Node) async {
        uploading = true
        defer { uploading = false; pickerItem = nil }
        guard let data = try? await item.loadTransferable(type: Data.self) else { store.lastError = "could not read photo"; return }
        let mime = item.supportedContentTypes.first?.preferredMIMEType ?? "image/jpeg"
        let sha = ImageTools.sha256Hex(data)
        let info = ImageTools.info(data)
        do {
            try await store.client.putBlob(spaceId: store.spaceId, sha256: sha, data: data, mime: mime)
            if let thumb = ImageTools.derivative(data, maxPixel: 256) {
                try await store.client.putBlob(spaceId: store.spaceId, sha256: sha, variant: "thumb", data: thumb, mime: "image/jpeg")
            }
            if let phone = ImageTools.derivative(data, maxPixel: 2048) {
                try await store.client.putBlob(spaceId: store.spaceId, sha256: sha, variant: "phone", data: phone, mime: "image/jpeg")
            }
        } catch {
            store.lastError = "upload failed: \(error.localizedDescription)"
            return
        }
        let capture = CaptureSidecar(capturedAt: info?.capturedAt, gps: info?.gps)
        let input = AttachmentInput(id: uuidv7(), kind: .image, mime: mime, filename: "\(sha.prefix(12)).jpg", byteSize: data.count,
                                    sha256: sha, url: nil, width: info?.width, height: info?.height, durationMs: nil,
                                    caption: "", sortKey: uuidv7(), capture: capture)
        await store.submit(.attachmentAdded(AttachmentAddedPayload(attachment: input)), nodeId: node.id)
    }

    private func describe(_ ev: Event) -> String {
        switch ev.body {
        case .nodeCreated(let p): return "Created \(p.kind.rawValue) “\(p.title)”"
        case .fieldChanged(let p): return "\(p.field.capitalized): \(render(p.before)) → \(render(p.after))"
        case .moved: return "Moved"
        case .archived: return "Archived"
        case .restored: return "Restored"
        case .labelAdded(let p): return "Added label \(p.label)"
        case .labelRemoved(let p): return "Removed label \(p.label)"
        case .attachmentAdded(let p): return "Added \(p.attachment.kind.rawValue) \(p.attachment.filename)"
        case .attachmentRemoved: return "Removed an attachment"
        case .attachmentCaptioned(let p): return "Captioned: \(p.caption)"
        case .noteEdited: return "Edited note"
        case .memberJoined(let p): return "\(p.displayName) joined as \(p.role.rawValue)"
        case .memberRoleChanged(let p): return "\(p.userId) is now \(p.role.rawValue)"
        }
    }
    private func render(_ v: JSONValue) -> String {
        switch v {
        case .null: return "none"
        case .string(let s): return s.replacingOccurrences(of: "_", with: " ")
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .bool(let b): return String(b)
        }
    }
}

/// An attachment image fetched through the authenticated client (plain AsyncImage cannot send headers).
struct BlobImage: View {
    let store: SpaceStore
    let sha256: String?
    let variant: String?
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(image, scale: 1, label: Text("photo")).resizable().scaledToFill()
            } else {
                Rectangle().fill(.quaternary).overlay(Image(systemName: "photo").foregroundStyle(.secondary))
            }
        }
        .task(id: "\(sha256 ?? "")/\(variant ?? "")") {
            guard let sha256, let data = await store.blob(sha256: sha256, variant: variant) else { return }
            image = ImageTools.cgImage(data)
        }
    }
}
