import CoreLocation
import Foundation

struct GraphEdge {
    let to: Int
    let length: Double
    let roadClass: Int
    let geometry: [CLLocationCoordinate2D]
}

/// A contracted OSM routing graph loaded from the bundled JSON. Vertices are
/// junctions/endpoints; each edge keeps its full polyline for drawing.
final class RoutingGraph: @unchecked Sendable {
    let coords: [CLLocationCoordinate2D]
    let flags: [UInt8]
    let adjacency: [[GraphEdge]]

    // Free-flow speeds (m/s) by road class 0..8, lower class = faster road.
    private static let speed: [Double] = [31, 27, 22, 18, 13, 11, 8, 4, 4]
    private static let maxSpeed = 31.0

    init(coords: [CLLocationCoordinate2D], flags: [UInt8], adjacency: [[GraphEdge]]) {
        self.coords = coords
        self.flags = flags
        self.adjacency = adjacency
    }

    static func load(from url: URL) -> RoutingGraph? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let vertsRaw = obj["vertices"] as? [[Double]],
              let edgesRaw = obj["edges"] as? [[Any]] else {
            return nil
        }

        var coords = [CLLocationCoordinate2D]()
        var flags = [UInt8]()
        coords.reserveCapacity(vertsRaw.count)
        flags.reserveCapacity(vertsRaw.count)
        for v in vertsRaw {
            coords.append(CLLocationCoordinate2D(latitude: v[0], longitude: v[1]))
            flags.append(UInt8(v.count > 2 ? Int(v[2]) : 0))
        }

        var adjacency = [[GraphEdge]](repeating: [], count: vertsRaw.count)
        for e in edgesRaw {
            guard e.count >= 6,
                  let u = (e[0] as? NSNumber)?.intValue,
                  let v = (e[1] as? NSNumber)?.intValue,
                  let len = (e[2] as? NSNumber)?.doubleValue,
                  let cls = (e[3] as? NSNumber)?.intValue,
                  let oneway = (e[4] as? NSNumber)?.intValue,
                  let flat = e[5] as? [Double] else { continue }
            var geo = [CLLocationCoordinate2D]()
            var i = 0
            while i + 1 < flat.count {
                geo.append(CLLocationCoordinate2D(latitude: flat[i], longitude: flat[i + 1]))
                i += 2
            }
            if oneway != -1 {
                adjacency[u].append(GraphEdge(to: v, length: len, roadClass: cls, geometry: geo))
            }
            if oneway != 1 {
                adjacency[v].append(GraphEdge(to: u, length: len, roadClass: cls, geometry: Array(geo.reversed())))
            }
        }
        return RoutingGraph(coords: coords, flags: flags, adjacency: adjacency)
    }

    func route(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Route? {
        guard let start = nearestVertex(to: from), let goal = nearestVertex(to: to) else { return nil }
        let n = coords.count
        var gScore = [Double](repeating: .greatestFiniteMagnitude, count: n)
        var cameFrom = [Int](repeating: -1, count: n)
        var cameEdge = [Int](repeating: -1, count: n)
        var closed = [Bool](repeating: false, count: n)
        gScore[start] = 0

        var heap = MinHeap()
        heap.push(start, priority: heuristic(start, goal))

        while let current = heap.pop() {
            if current == goal { break }
            if closed[current] { continue }
            closed[current] = true
            for (idx, edge) in adjacency[current].enumerated() {
                let tentative = gScore[current] + edge.length / Self.speed[edge.roadClass]
                if tentative < gScore[edge.to] {
                    gScore[edge.to] = tentative
                    cameFrom[edge.to] = current
                    cameEdge[edge.to] = idx
                    heap.push(edge.to, priority: tentative + heuristic(edge.to, goal))
                }
            }
        }

        guard gScore[goal] < .greatestFiniteMagnitude else { return nil }

        var path = [Int]()
        var cur = goal
        while cur != -1 {
            path.append(cur)
            cur = cameFrom[cur]
        }
        path.reverse()

        var geometry = [CLLocationCoordinate2D]()
        var distance = 0.0
        for i in 0..<(path.count - 1) {
            let edge = adjacency[path[i]][cameEdge[path[i + 1]]]
            if geometry.isEmpty {
                geometry.append(contentsOf: edge.geometry)
            } else {
                geometry.append(contentsOf: edge.geometry.dropFirst())
            }
            distance += edge.length
        }

        let giveWay = path.reduce(into: 0) { $0 += flags[$1] != 0 ? 1 : 0 }
        return Route(coordinates: geometry, distanceMeters: distance, giveWayCount: giveWay, isPreview: false)
    }

    func nearestVertex(to c: CLLocationCoordinate2D) -> Int? {
        var best = -1
        var bestDist = Double.greatestFiniteMagnitude
        let cosLat = cos(c.latitude * .pi / 180)
        for (i, vc) in coords.enumerated() {
            let dLat = vc.latitude - c.latitude
            let dLon = (vc.longitude - c.longitude) * cosLat
            let d = dLat * dLat + dLon * dLon
            if d < bestDist {
                bestDist = d
                best = i
            }
        }
        return best >= 0 ? best : nil
    }

    private func heuristic(_ a: Int, _ goal: Int) -> Double {
        haversine(coords[a], coords[goal]) / Self.maxSpeed
    }
}

func haversine(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
    let r = 6_371_000.0
    let lat1 = a.latitude * .pi / 180
    let lat2 = b.latitude * .pi / 180
    let dLat = (b.latitude - a.latitude) * .pi / 180
    let dLon = (b.longitude - a.longitude) * .pi / 180
    let h = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
    return 2 * r * asin(min(1, sqrt(h)))
}

private struct MinHeap {
    private var items: [(priority: Double, vertex: Int)] = []

    mutating func push(_ vertex: Int, priority: Double) {
        items.append((priority, vertex))
        var c = items.count - 1
        while c > 0 {
            let p = (c - 1) / 2
            if items[c].priority < items[p].priority {
                items.swapAt(c, p)
                c = p
            } else {
                break
            }
        }
    }

    mutating func pop() -> Int? {
        guard !items.isEmpty else { return nil }
        items.swapAt(0, items.count - 1)
        let top = items.removeLast()
        if !items.isEmpty {
            var p = 0
            let count = items.count
            while true {
                let l = 2 * p + 1
                let r = 2 * p + 2
                var s = p
                if l < count && items[l].priority < items[s].priority { s = l }
                if r < count && items[r].priority < items[s].priority { s = r }
                if s == p { break }
                items.swapAt(p, s)
                p = s
            }
        }
        return top.vertex
    }
}
