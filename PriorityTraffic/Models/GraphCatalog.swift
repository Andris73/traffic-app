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

private struct UserAreaMeta: Codable {
    let id: String
    let name: String
    let bbox: [Double]
    let sizeBytes: Int
}

@MainActor
final class GraphStore: ObservableObject {
    @Published var areas: [GraphArea] = []
    @Published var userAreas: [GraphArea] = []
    @Published var installed: Set<String> = []
    @Published var downloading: Set<String> = []
    @Published private(set) var activeID: String

    private static let manifestURL = URL(string:
        "https://raw.githubusercontent.com/Andris73/traffic-app/master/graphs/manifest.json")!
    private static let activeKey = "activeGraphID"
    private static let defaultID = "cambridge"
    private static let bundledResource = "graph-cambridge"
    private static let userAreasFile = "user-areas.json"

    init() {
        activeID = UserDefaults.standard.string(forKey: Self.activeKey) ?? Self.defaultID
        seedBundled()
        loadUserAreas()
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
        if userAreas.contains(where: { $0.id == area.id }) {
            removeCustom(id: area.id)
            return
        }
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

    func saveCustomGraph(id: String, data: Data) -> URL? {
        guard let dir = graphsDirectory() else { return nil }
        let url = dir.appendingPathComponent("\(id).json")
        try? FileManager.default.removeItem(at: url)
        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    func registerCustom(area: GraphArea) {
        userAreas.removeAll { $0.id == area.id }
        userAreas.append(area)
        persistUserAreas()
        refreshInstalled()
    }

    func removeCustom(id: String) {
        userAreas.removeAll { $0.id == id }
        if let dir = graphsDirectory() {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(id).json"))
        }
        persistUserAreas()
        refreshInstalled()
        if activeID == id {
            setActive(Self.defaultID)
        }
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
            for name in contents where name.hasSuffix(".json") && name != Self.userAreasFile {
                ids.insert(String(name.dropLast(".json".count)))
            }
        }
        installed = ids
    }

    private func loadUserAreas() {
        guard let dir = graphsDirectory() else { return }
        let url = dir.appendingPathComponent(Self.userAreasFile)
        guard let data = try? Data(contentsOf: url),
              let metas = try? JSONDecoder().decode([UserAreaMeta].self, from: data) else {
            return
        }
        userAreas = metas.compactMap { meta in
            let fileURL = dir.appendingPathComponent("\(meta.id).json")
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
            return GraphArea(
                id: meta.id,
                name: meta.name,
                bbox: meta.bbox,
                sizeBytes: meta.sizeBytes,
                url: fileURL,
                bundled: false
            )
        }
    }

    private func persistUserAreas() {
        guard let dir = graphsDirectory() else { return }
        let metas = userAreas.map {
            UserAreaMeta(id: $0.id, name: $0.name, bbox: $0.bbox, sizeBytes: $0.sizeBytes)
        }
        if let data = try? JSONEncoder().encode(metas) {
            try? data.write(to: dir.appendingPathComponent(Self.userAreasFile))
        }
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
