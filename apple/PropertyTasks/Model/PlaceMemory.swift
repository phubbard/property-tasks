import Foundation

/// Where the last few captures went, per Space, so the capture sheet can default to the
/// last-used container and offer recents (DESIGN.md §3). Node ids only; the store decides
/// whether they still exist.
struct PlaceMemory {
    static let maxRecents = 5
    private let defaults: UserDefaults
    private let spaceId: String

    init(spaceId: String, defaults: UserDefaults = .standard) {
        self.spaceId = spaceId
        self.defaults = defaults
    }

    private var lastKey: String { "capture.lastPlace.\(spaceId)" }
    private var recentsKey: String { "capture.recentPlaces.\(spaceId)" }

    var lastPlace: String? { defaults.string(forKey: lastKey) }

    var recents: [String] { defaults.stringArray(forKey: recentsKey) ?? [] }

    /// Record a capture landing in `nodeId`: it becomes the default and moves to the front of recents.
    func noteUse(_ nodeId: String) {
        defaults.set(nodeId, forKey: lastKey)
        var r = recents.filter { $0 != nodeId }
        r.insert(nodeId, at: 0)
        defaults.set(Array(r.prefix(Self.maxRecents)), forKey: recentsKey)
    }
}
