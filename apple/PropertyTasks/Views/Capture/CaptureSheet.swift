#if os(iOS)
import PhotosUI
import PropertyTasksCore
import SwiftUI

/// Where a captured item lands. `.inbox` is the Space's root Inbox whether or not it exists
/// yet; it is created on first use.
enum PlaceChoice: Equatable, Hashable {
    case inbox
    case node(String)

    var nodeId: String? { if case .node(let id) = self { return id } else { return nil } }
}

/// The headline flow (DESIGN.md §3): camera first, then one line of title, a place that
/// defaults to the last one used, a priority chip, Done. Everything applies locally through
/// `SpaceStore`; the photo bytes upload afterwards from the store's queue.
struct CaptureSheet: View {
    let store: SpaceStore
    @Environment(\.dismiss) private var dismiss

    private enum Stage { case camera, details }
    @State private var stage: Stage = .camera
    @State private var shots: [Shot] = []
    @State private var title = ""
    @State private var place: PlaceChoice = .inbox
    @State private var priority: Priority = .normal
    @State private var saving = false
    @State private var error: String?

    struct Shot: Identifiable {
        let id = UUID()
        var photo: CapturedPhoto
        var preview: CGImage?
    }

    var body: some View {
        Group {
            switch stage {
            case .camera:
                CameraStage(shots: $shots, onCancel: { dismiss() }, onNext: { stage = .details })
            case .details:
                details
            }
        }
        .interactiveDismissDisabled(!shots.isEmpty || !title.isEmpty)
        .onAppear { place = defaultPlace() }
    }

    private var details: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What needs doing?", text: $title, axis: .vertical)
                        .lineLimit(1...3)
                        .submitLabel(.done)
                } footer: {
                    Text("Tap the microphone on the keyboard to dictate.")
                }

                Section("Where") {
                    NavigationLink {
                        PlacePicker(store: store, selection: $place)
                    } label: {
                        LabeledContent("Place", value: placeLabel(place))
                    }
                }

                Section("Priority") {
                    PriorityChips(selection: $priority)
                }

                if !shots.isEmpty {
                    Section("Photos") {
                        ScrollView(.horizontal) {
                            HStack(spacing: 8) {
                                ForEach(shots) { shot in
                                    ShotThumb(image: shot.preview)
                                        .frame(width: 72, height: 72)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                        .contextMenu { Button("Remove photo", role: .destructive) { shots.removeAll { $0.id == shot.id } } }
                                }
                                Button { stage = .camera } label: {
                                    Image(systemName: "camera.badge.ellipsis").font(.title2)
                                        .frame(width: 72, height: 72).background(.quaternary).clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                                .accessibilityLabel("Take more photos")
                            }
                        }
                    }
                }

                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("New item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { stage = .camera } label: { Label("Camera", systemImage: "chevron.left").labelStyle(.titleAndIcon) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Done") { Task { await done() } }
                        .disabled(saving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func defaultPlace() -> PlaceChoice {
        let memory = PlaceMemory(spaceId: store.spaceId)
        if let last = memory.lastPlace, let n = store.store.getNode(last), n.kind == .container, n.archivedAt == nil {
            return n.id == store.inboxId ? .inbox : .node(n.id)
        }
        return .inbox
    }

    private func placeLabel(_ p: PlaceChoice) -> String {
        switch p {
        case .inbox: return SpaceStore.inboxTitle
        case .node(let id):
            guard let n = store.store.getNode(id) else { return "?" }
            let path = store.path(for: id)
            return path.isEmpty ? n.title : "\(path) › \(n.title)"
        }
    }

    private func done() async {
        saving = true
        defer { saving = false }
        let photos = shots.map(\.photo)
        guard let nodeId = await store.createCapturedItem(title: title, parentId: place.nodeId, priority: priority, photos: photos) else {
            error = store.lastError ?? "Could not save the item."
            return
        }
        if let parent = store.store.getNode(nodeId)?.parentId {
            PlaceMemory(spaceId: store.spaceId).noteUse(parent)
        }
        dismiss()
    }
}

/// Full-screen viewfinder with a shutter, the shots so far, a library fallback for devices
/// (and the Simulator) without a camera, and Next.
struct CameraStage: View {
    @Binding var shots: [CaptureSheet.Shot]
    let onCancel: () -> Void
    let onNext: () -> Void

    @State private var engine = CameraEngine()
    @State private var sensors = CaptureSensors()
    @State private var cameraState: CameraEngine.State = .idle
    @State private var shooting = false
    @State private var flash = false
    @State private var pickerItems: [PhotosPickerItem] = []

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch cameraState {
            case .running:
                CameraPreview(session: engine.session).ignoresSafeArea()
            case .unavailable(let why):
                VStack(spacing: 12) {
                    Image(systemName: "camera.slash").font(.largeTitle)
                    Text(why).multilineTextAlignment(.center)
                    Text("You can still pick photos from your library below.").font(.footnote)
                }
                .foregroundStyle(.white.opacity(0.8)).padding(32)
            case .idle, .starting:
                ProgressView().tint(.white)
            }
            if flash { Color.white.ignoresSafeArea().transition(.opacity) }

            VStack {
                HStack {
                    Button("Cancel", action: onCancel).foregroundStyle(.white)
                    Spacer()
                    if let fix = sensors.gps {
                        Label(fix.accuracyM.map { "±\(Int($0)) m" } ?? "GPS", systemImage: "location.fill")
                            .font(.caption).foregroundStyle(.white.opacity(0.8))
                    }
                }
                .padding()
                Spacer()
                if !shots.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 6) {
                            ForEach(shots) { s in
                                ShotThumb(image: s.preview).frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 6))
                                    .contextMenu { Button("Remove photo", role: .destructive) { shots.removeAll { $0.id == s.id } } }
                            }
                        }
                        .padding(.horizontal)
                    }
                    .frame(height: 60)
                }
                HStack {
                    PhotosPicker(selection: $pickerItems, maxSelectionCount: 10, matching: .images) {
                        Image(systemName: "photo.on.rectangle").font(.title2).frame(width: 56, height: 56)
                    }
                    .foregroundStyle(.white)
                    .accessibilityLabel("Choose from library")
                    Spacer()
                    Button { Task { await shoot() } } label: {
                        ZStack {
                            Circle().stroke(.white, lineWidth: 4).frame(width: 76, height: 76)
                            Circle().fill(.white).frame(width: 62, height: 62)
                        }
                    }
                    .disabled(cameraState != .running || shooting)
                    .opacity(cameraState == .running ? 1 : 0.3)
                    .accessibilityLabel("Take photo")
                    Spacer()
                    Button(action: onNext) {
                        Text(shots.isEmpty ? "Skip" : "Next")
                            .fontWeight(.semibold)
                            .frame(width: 56, height: 56)
                            .overlay(alignment: .topTrailing) {
                                if !shots.isEmpty {
                                    Text("\(shots.count)").font(.caption2).bold().padding(5)
                                        .background(Color.accentColor, in: Circle()).foregroundStyle(.white)
                                }
                            }
                    }
                    .foregroundStyle(.white)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
        .statusBarHidden()
        .task {
            sensors.start()
            cameraState = .starting
            cameraState = await engine.start()
        }
        .onDisappear {
            sensors.stop()
            engine.stop()
        }
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await importPicked(items) }
        }
    }

    private func shoot() async {
        shooting = true
        defer { shooting = false }
        let sidecar = sensors.snapshot()
        do {
            let data = try await engine.capture()
            withAnimation(.easeOut(duration: 0.08)) { flash = true }
            try? await Task.sleep(for: .milliseconds(80))
            withAnimation(.easeIn(duration: 0.15)) { flash = false }
            await append(CapturedPhoto(data: data, mime: "image/jpeg", sensors: sidecar, capturedAt: sidecar.capturedAt))
        } catch {
            // Leave the viewfinder up; the next shot can succeed.
        }
    }

    private func importPicked(_ items: [PhotosPickerItem]) async {
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            let mime = item.supportedContentTypes.first?.preferredMIMEType ?? "image/jpeg"
            await append(CapturedPhoto(data: data, mime: mime))
        }
        pickerItems = []
    }

    private func append(_ photo: CapturedPhoto) async {
        let data = photo.data
        let preview = await Task.detached { ImageTools.derivative(data, maxPixel: 256).flatMap(ImageTools.cgImage) }.value
        shots.append(CaptureSheet.Shot(photo: photo, preview: preview))
    }
}

struct ShotThumb: View {
    let image: CGImage?
    var body: some View {
        if let image {
            Image(image, scale: 1, label: Text("photo")).resizable().scaledToFill()
        } else {
            Rectangle().fill(.quaternary).overlay(Image(systemName: "photo"))
        }
    }
}

/// Horizontal chip row; `.none` is left out because a captured item is a task.
struct PriorityChips: View {
    @Binding var selection: Priority
    private let options: [Priority] = [.low, .normal, .high, .urgent]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(options, id: \.self) { p in
                Button { selection = p } label: {
                    Text(p.rawValue.capitalized)
                        .font(.subheadline.weight(selection == p ? .semibold : .regular))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(selection == p ? Color.accentColor : Color.clear, in: Capsule())
                        .overlay(Capsule().stroke(selection == p ? Color.accentColor : Color.secondary.opacity(0.4)))
                        .foregroundStyle(selection == p ? .white : .primary)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == p ? .isSelected : [])
            }
        }
    }
}

/// Recents first, the Inbox, then every live container with its path, searchable.
struct PlacePicker: View {
    let store: SpaceStore
    @Binding var selection: PlaceChoice
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    var body: some View {
        let _ = store.version
        let memory = PlaceMemory(spaceId: store.spaceId)
        let recents = memory.recents.compactMap { store.store.getNode($0) }.filter { $0.kind == .container && $0.archivedAt == nil && $0.id != store.inboxId }
        let all = store.containers
            .filter { $0.id != store.inboxId }
            .map { (node: $0, path: fullPath($0)) }
            .filter { search.isEmpty || $0.path.localizedCaseInsensitiveContains(search) }
            .sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
        List {
            if search.isEmpty {
                if !recents.isEmpty {
                    Section("Recent") {
                        ForEach(recents) { n in row(.node(n.id), title: n.title, subtitle: store.path(for: n.id)) }
                    }
                }
                Section {
                    row(.inbox, title: SpaceStore.inboxTitle, subtitle: store.inboxId == nil ? "Created when first used" : "Sort it out later")
                }
            }
            Section(search.isEmpty ? "All places" : "Matches") {
                ForEach(all, id: \.node.id) { entry in row(.node(entry.node.id), title: entry.node.title, subtitle: store.path(for: entry.node.id)) }
                if all.isEmpty { Text("No places match").foregroundStyle(.secondary) }
            }
        }
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search places")
        .navigationTitle("Where")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func fullPath(_ n: Node) -> String {
        let p = store.path(for: n.id)
        return p.isEmpty ? n.title : "\(p) › \(n.title)"
    }

    private func row(_ choice: PlaceChoice, title: String, subtitle: String) -> some View {
        Button {
            selection = choice
            dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    if !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                if selection == choice { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
            }
        }
        .buttonStyle(.plain)
    }
}
#endif
