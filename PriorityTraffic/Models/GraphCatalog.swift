import Combine
import Foundation

struct GraphArea: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let bbox: [Double]
    let sizeBytes: Int
    let url: URL
    let bundled: Bool
}

struct GraphManifest: Codable {
    let areas: [GraphArea]
}

@MainActor
final class GraphStore: ObservableObject {
    @Published var areas: [GraphArea] = []
    @Published var installed: Set<String> = []
    @Published var downloading: Set<String> = []
    @Published private(set) var activeID: String

    private static let manifestURL = URL(string:
        "https://raw.githubusercontent.com/Andris73/traffic-app/master/graphs/manifest.json")!
    private static let activeKey = "activeGraphID"
    private static let defaultID = "cambridge"
    private static let bundledResource = "graph-cambridge"

    init() {
        activeID = UserDefaults.standard.string(forKey: Self.activeKey) ?? Self.defaultID
        seedBundled()
        refreshInstalled()
    }

    func refreshManifest() async {
        guard let (data, _) = try? await URLSession.shared.data(from: Self.manifestURL),
              let manifest = try? JSONDecoder().decode(GraphManifest.self, from: data) else {
            return
        }
        areas = manifest.areas
        refreshInstalled()
    }

    func download(_ area: GraphArea) async {
        guard !downloading.contains(area.id) else { return }
        downloading.insert(area.id)
        defer { downloading.remove(area.id) }

        guard let dir = graphsDirectory() else { return }
        let dest = dir.appendingPathComponent("\(area.id).json")
        do {
            let (tempURL, _) = try await URLSession.shared.download(from: area.url)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tempURL, to: dest)
            refreshInstalled()
        } catch {
            // Silent for now; UI surfaces it via lack of state change.
        }
    }

    func delete(_ area: GraphArea) {
        guard area.id != Self.defaultID else { return }
        if let dir = graphsDirectory() {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(area.id).json"))
            refreshInstalled()
        }
        if activeID == area.id {
            setActive(Self.defaultID)
        }
    }

    func setActive(_ id: String) {
        guard installed.contains(id) else { return }
        activeID = id
        UserDefaults.standard.set(id, forKey: Self.activeKey)
    }

    func activeURL() -> URL? {
        localURL(for: activeID) ?? localURL(for: Self.defaultID)
    }

    func localURL(for areaID: String) -> URL? {
        if areaID == Self.defaultID,
           let url = Bundle.main.url(forResource: Self.bundledResource, withExtension: "json") {
            return url
        }
        if let dir = graphsDirectory() {
            let url = dir.appendingPathComponent("\(areaID).json")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    private func refreshInstalled() {
        var ids = Set<String>()
        if Bundle.main.url(forResource: Self.bundledResource, withExtension: "json") != nil {
            ids.insert(Self.defaultID)
        }
        if let dir = graphsDirectory(),
           let contents = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
            for name in contents where name.hasSuffix(".json") {
                ids.insert(String(name.dropLast(".json".count)))
            }
        }
        installed = ids
    }

    /// Make sure the catalogue always contains the bundled default, even before
    /// the network manifest has been fetched.
    private func seedBundled() {
        guard let url = Bundle.main.url(forResource: Self.bundledResource, withExtension: "json"),
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int else {
            return
        }
        areas = [GraphArea(
            id: Self.defaultID,
            name: "Cambridge area",
            bbox: [52.0, -0.05, 52.35, 0.55],
            sizeBytes: size,
            url: URL(string: "https://raw.githubusercontent.com/Andris73/traffic-app/master/graphs/cambridge.json")!,
            bundled: true
        )]
    }

    private func graphsDirectory() -> URL? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        let dir = base.appendingPathComponent("graphs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
