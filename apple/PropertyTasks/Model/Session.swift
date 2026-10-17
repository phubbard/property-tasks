import Foundation
import Observation
import PropertyTasksCore

/// Who we are and which Worker we talk to. Settings persist in UserDefaults.
/// TODO(auth): replace the dev user with a real session token (DESIGN.md §6).
@MainActor @Observable
final class Session {
    private let defaults = UserDefaults.standard

    var serverURL: String { didSet { defaults.set(serverURL, forKey: "serverURL"); rebuild() } }
    var devUser: String { didSet { defaults.set(devUser, forKey: "devUser"); rebuild() } }
    let deviceId: String
    private(set) var client: SyncClient

    init() {
        let url = defaults.string(forKey: "serverURL") ?? "http://localhost:8787"
        let user = defaults.string(forKey: "devUser") ?? "paul"
        let device: String
        if let d = defaults.string(forKey: "deviceId") { device = d }
        else { device = "apple-" + uuidv7(); defaults.set(device, forKey: "deviceId") }
        serverURL = url
        devUser = user
        deviceId = device
        client = Session.makeClient(url: url, user: user)
    }

    private static func makeClient(url: String, user: String) -> SyncClient {
        SyncClient(baseURL: URL(string: url) ?? URL(string: "http://localhost:8787")!, auth: .devUser(user))
    }

    private func rebuild() {
        client = Session.makeClient(url: serverURL, user: devUser)
    }

    static var buildInfo: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let v = info["CFBundleShortVersionString"] as? String ?? "?"
        let b = info["CFBundleVersion"] as? String ?? "?"
        let sha = info["PTGitSHA"] as? String ?? "?"
        let date = info["PTBuildDate"] as? String ?? "?"
        return "\(v) (\(b)) \(sha) \(date)"
    }
}
