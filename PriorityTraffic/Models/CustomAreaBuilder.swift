import CoreLocation
import Foundation

/// Builds a routing graph for a user-defined bbox by querying Overpass directly
/// from the device, contracting shape points into a vertex/edge graph, and
/// writing it into the GraphStore.
@MainActor
final class CustomAreaBuilder: ObservableObject {
    enum Phase: Equatable {
        case idle, fetching, parsing, contracting, saving, done, failed
    }

    @Published var phase: Phase = .idle
    @Published var message: String = ""

    func build(bbox: [Double], name: String, store: GraphStore) async -> GraphArea? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            setStatus(.failed, "Name required")
            return nil
        }
        let id = "user-" + OverpassWorker.slug(trimmedName)

        setStatus(.fetching, "Fetching OSM data from Overpass…")
        let data = await OverpassWorker.fetchOverpass(bbox: bbox)
        guard let data else {
            setStatus(.failed, "Overpass request failed. Try a smaller area.")
            return nil
        }

        setStatus(.parsing, "Parsing \(byteSize(data.count))…")
        let parsed = await Task.detached(priority: .userInitiated) {
            OverpassWorker.parseElements(data)
        }.value
        guard let (nodes, ways) = parsed else {
            setStatus(.failed, "Could not decode OSM data")
            return nil
        }

        setStatus(.contracting, "Building routing graph (\(ways.count) ways)…")
        let graphJSON = await Task.detached(priority: .userInitiated) {
            OverpassWorker.buildGraphJSON(bbox: bbox, nodes: nodes, ways: ways)
        }.value
        guard let graphJSON else {
            setStatus(.failed, "Could not build graph")
            return nil
        }

        setStatus(.saving, "Saving \(byteSize(graphJSON.count))…")
        guard let url = store.saveCustomGraph(id: id, data: graphJSON) else {
            setStatus(.failed, "Could not save graph file")
            return nil
        }

        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? graphJSON.count
        let area = GraphArea(
            id: id,
            name: trimmedName,
            bbox: bbox,
            sizeBytes: size,
            url: url,
            bundled: false
        )
        store.registerCustom(area: area)
        store.setActive(id)
        setStatus(.done, "Ready")
        return area
    }

    private func setStatus(_ phase: Phase, _ message: String) {
        self.phase = phase
        self.message = message
    }

    private func byteSize(_ bytes: Int) -> String {
        if bytes >= 1_000_000 { return String(format: "%.1f MB", Double(bytes) / 1_000_000) }
        return String(format: "%.0f KB", Double(bytes) / 1_000)
    }
}

// Non-isolated helpers so heavy work can run off the main actor.
private enum OverpassWorker {
    struct OSMNode {
        let id: Int
        let lat: Double
        let lon: Double
        let highway: String?
    }

    struct OSMWay {
        let nodeIDs: [Int]
        let highway: String
        let junction: String?
        let oneway: String?
    }

    static let endpoints: [URL] = [
        URL(string: "https://overpass.kumi.systems/api/interpreter")!,
        URL(string: "https://overpass-api.de/api/interpreter")!,
        URL(string: "https://maps.mail.ru/osm/tools/overpass/api/interpreter")!,
    ]

    static let drivable = "motorway|trunk|primary|secondary|tertiary|unclassified|residential|living_street|motorway_link|trunk_link|primary_link|secondary_link|tertiary_link"

    static let classRank: [String: Int] = [
        "motorway": 0, "trunk": 1, "primary": 2, "secondary": 3, "tertiary": 4,
        "unclassified": 5, "residential": 6, "living_street": 7, "service": 8,
        "motorway_link": 0, "trunk_link": 1, "primary_link": 2,
        "secondary_link": 3, "tertiary_link": 4,
    ]

    static func slug(_ s: String) -> String {
        var out = ""
        var lastDash = false
        for scalar in s.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                out.append(Character(scalar))
                lastDash = false
            } else if !lastDash {
                out.append("-")
                lastDash = true
            }
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "area" : trimmed
    }

    static func overpassQuery(bbox: [Double]) -> String {
        let s = bbox[0], w = bbox[1], n = bbox[2], e = bbox[3]
        return "[out:json][timeout:300];(way[\"highway\"~\"^(\(drivable))$\"](\(s),\(w),\(n),\(e)););(._;>;);out body;"
    }

    static func fetchOverpass(bbox: [Double]) async -> Data? {
        let query = overpassQuery(bbox: bbox)
        var components = URLComponents()
        components.queryItems = [URLQueryItem(name: "data", value: query)]
        guard let body = components.percentEncodedQuery?.data(using: .utf8) else { return nil }

        for endpoint in endpoints {
            var req = URLRequest(url: endpoint)
            req.httpMethod = "POST"
            req.httpBody = body
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.setValue("priority-traffic-mobile/1.0", forHTTPHeaderField: "User-Agent")
            req.timeoutInterval = 300
            do {
                let (data, response) = try await URLSession.shared.data(for: req)
                if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                    return data
                }
            } catch {
                continue
            }
        }
        return nil
    }

    static func parseElements(_ data: Data) -> ([OSMNode], [OSMWay])? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let elements = obj["elements"] as? [[String: Any]] else {
            return nil
        }
        var nodes = [OSMNode]()
        nodes.reserveCapacity(elements.count)
        var ways = [OSMWay]()
        ways.reserveCapacity(elements.count / 10)

        for el in elements {
            guard let type = el["type"] as? String,
                  let nsId = el["id"] as? NSNumber else { continue }
            let id = Int(nsId.int64Value)
            let tags = el["tags"] as? [String: String]

            switch type {
            case "node":
                guard let lat = (el["lat"] as? NSNumber)?.doubleValue,
                      let lon = (el["lon"] as? NSNumber)?.doubleValue else { continue }
                nodes.append(OSMNode(id: id, lat: lat, lon: lon, highway: tags?["highway"]))
            case "way":
                guard let raw = el["nodes"] as? [Any] else { continue }
                let nodeIDs = raw.compactMap { ($0 as? NSNumber).map { Int($0.int64Value) } }
                guard nodeIDs.count >= 2, let highway = tags?["highway"] else { continue }
                ways.append(OSMWay(
                    nodeIDs: nodeIDs,
                    highway: highway,
                    junction: tags?["junction"],
                    oneway: tags?["oneway"]
                ))
            default:
                continue
            }
        }
        return (nodes, ways)
    }

    static func buildGraphJSON(bbox: [Double], nodes: [OSMNode], ways: [OSMWay]) -> Data? {
        var nodeIndex = [Int: Int]()
        nodeIndex.reserveCapacity(nodes.count)
        for (i, n) in nodes.enumerated() { nodeIndex[n.id] = i }

        var usage = [Int](repeating: 0, count: nodes.count)
        for way in ways {
            for nid in way.nodeIDs {
                if let idx = nodeIndex[nid] { usage[idx] += 1 }
            }
        }

        func nodeFlags(_ n: OSMNode) -> Int {
            switch n.highway {
            case "give_way": return 1
            case "stop": return 2
            case "traffic_signals": return 4
            case "mini_roundabout": return 8
            default: return 0
            }
        }

        var isVertex = [Bool](repeating: false, count: nodes.count)
        for way in ways {
            for (i, nid) in way.nodeIDs.enumerated() {
                guard let idx = nodeIndex[nid] else { continue }
                let endpoint = i == 0 || i == way.nodeIDs.count - 1
                if endpoint || usage[idx] > 1 || nodeFlags(nodes[idx]) != 0 {
                    isVertex[idx] = true
                }
            }
        }

        var vindex = [Int: Int]()
        var vertices: [[Any]] = []

        func vertexID(for idx: Int) -> Int {
            if let v = vindex[idx] { return v }
            let n = nodes[idx]
            let id = vertices.count
            vindex[idx] = id
            vertices.append([
                (n.lat * 1_000_000).rounded() / 1_000_000,
                (n.lon * 1_000_000).rounded() / 1_000_000,
                nodeFlags(n),
            ])
            return id
        }

        var edges: [[Any]] = []

        for way in ways {
            let cls = classRank[way.highway] ?? 8
            let isRoundabout = way.junction == "roundabout" || way.junction == "circular"
            let oneway: Int
            if isRoundabout || way.oneway == "yes" || way.oneway == "true" || way.oneway == "1" {
                oneway = 1
            } else if way.oneway == "-1" {
                oneway = -1
            } else {
                oneway = 0
            }

            guard let firstIdx = nodeIndex[way.nodeIDs[0]] else { continue }
            var segStart = firstIdx
            var coords: [Double] = [
                (nodes[firstIdx].lat * 1_000_000).rounded() / 1_000_000,
                (nodes[firstIdx].lon * 1_000_000).rounded() / 1_000_000,
            ]
            var length = 0.0

            for i in 1..<way.nodeIDs.count {
                guard let prevIdx = nodeIndex[way.nodeIDs[i - 1]],
                      let curIdx = nodeIndex[way.nodeIDs[i]] else { continue }
                length += haversineMeters(
                    nodes[prevIdx].lat, nodes[prevIdx].lon,
                    nodes[curIdx].lat, nodes[curIdx].lon
                )
                coords.append((nodes[curIdx].lat * 1_000_000).rounded() / 1_000_000)
                coords.append((nodes[curIdx].lon * 1_000_000).rounded() / 1_000_000)
                if isVertex[curIdx] {
                    if curIdx != segStart, length > 0 {
                        edges.append([
                            vertexID(for: segStart),
                            vertexID(for: curIdx),
                            (length * 10).rounded() / 10,
                            cls,
                            oneway,
                            coords,
                        ])
                    }
                    segStart = curIdx
                    coords = [
                        (nodes[curIdx].lat * 1_000_000).rounded() / 1_000_000,
                        (nodes[curIdx].lon * 1_000_000).rounded() / 1_000_000,
                    ]
                    length = 0.0
                }
            }
        }

        let out: [String: Any] = [
            "bbox": bbox,
            "vertices": vertices,
            "edges": edges,
        ]
        return try? JSONSerialization.data(withJSONObject: out, options: [])
    }

    static func haversineMeters(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let r = 6_371_000.0
        let phi1 = lat1 * .pi / 180
        let phi2 = lat2 * .pi / 180
        let dPhi = (lat2 - lat1) * .pi / 180
        let dLambda = (lon2 - lon1) * .pi / 180
        let h = sin(dPhi / 2) * sin(dPhi / 2) + cos(phi1) * cos(phi2) * sin(dLambda / 2) * sin(dLambda / 2)
        return 2 * r * asin(min(1, sqrt(h)))
    }
}
