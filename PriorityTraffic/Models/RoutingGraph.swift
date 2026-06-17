import CoreLocation
import Foundation

struct GraphEdge {
    let to: Int
    let length: Double
    let roadClass: Int
    let bearingIn: Double      // heading at start (leaving source vertex)
    let bearingOut: Double     // heading at end (arriving at destination vertex)
    let geometry: [CLLocationCoordinate2D]
}

/// A contracted OSM routing graph loaded from a JSON file. Vertices are
/// junctions/endpoints; each edge keeps its full polyline for drawing.
final class RoutingGraph: @unchecked Sendable {
    let coords: [CLLocationCoordinate2D]
    let flags: [UInt8]
    let adjacency: [[GraphEdge]]

    // Free-flow speeds (m/s) by road class 0..8, lower class = faster road.
    private static let speed: [Double] = [31, 27, 22, 18, 13, 11, 8, 4, 4]
    private static let maxSpeed = 31.0

    // Node-flag bits (must match build_graph.py).
    private static let flagGiveWay: UInt8 = 1
    private static let flagStop: UInt8 = 2
    private static let flagSignal: UInt8 = 4
    private static let flagMiniRoundabout: UInt8 = 8

    // Give-way penalties (seconds) — scaled by the user's aversion factor.
    private static let nodeGiveWay = 20.0
    private static let nodeStop = 35.0
    private static let nodeMiniRoundabout = 18.0
    private static let classStepPenalty = 16.0     // per class jumped (smaller -> bigger)
    private static let rightTurnPenalty = 14.0     // right turn crossing oncoming traffic

    // Signals are NOT a give-way — you have priority on green. Model them as a
    // small flat delay that always applies (not scaled by aversion) and is not
    // counted as a give-way event.
    private static let signalPenalty = 6.0

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
            guard geo.count >= 2 else { continue }
            if oneway != -1 {
                let bIn = bearing(geo[0], geo[1])
                let bOut = bearing(geo[geo.count - 2], geo[geo.count - 1])
                adjacency[u].append(GraphEdge(
                    to: v, length: len, roadClass: cls,
                    bearingIn: bIn, bearingOut: bOut, geometry: geo
                ))
            }
            if oneway != 1 {
                let rev = Array(geo.reversed())
                let bIn = bearing(rev[0], rev[1])
                let bOut = bearing(rev[rev.count - 2], rev[rev.count - 1])
                adjacency[v].append(GraphEdge(
                    to: u, length: len, roadClass: cls,
                    bearingIn: bIn, bearingOut: bOut, geometry: rev
                ))
            }
        }
        return RoutingGraph(coords: coords, flags: flags, adjacency: adjacency)
    }

    func route(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        multiplier: Double = 1.0
    ) -> Route? {
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

            let prevEdge: GraphEdge? = {
                guard cameFrom[current] >= 0, cameEdge[current] >= 0 else { return nil }
                return adjacency[cameFrom[current]][cameEdge[current]]
            }()

            for (idx, edge) in adjacency[current].enumerated() {
                let edgeTime = edge.length / Self.speed[edge.roadClass]
                var transition = 0.0
                if let prev = prevEdge {
                    let c = transitionCosts(from: prev, at: current, to: edge)
                    transition = c.giveWay * multiplier + c.signal
                }
                let tentative = gScore[current] + edgeTime + transition
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
        var travelTime = 0.0
        for i in 0..<(path.count - 1) {
            let edge = adjacency[path[i]][cameEdge[path[i + 1]]]
            if geometry.isEmpty {
                geometry.append(contentsOf: edge.geometry)
            } else {
                geometry.append(contentsOf: edge.geometry.dropFirst())
            }
            distance += edge.length
            travelTime += edge.length / Self.speed[edge.roadClass]
        }

        var events = [GiveWayEvent]()
        if path.count >= 3 {
            for i in 1..<(path.count - 1) {
                let arrive = adjacency[path[i - 1]][cameEdge[path[i]]]
                let leave = adjacency[path[i]][cameEdge[path[i + 1]]]
                // Only true give-ways are events; signal-only stops are excluded.
                if transitionCosts(from: arrive, at: path[i], to: leave).giveWay > 0 {
                    let v = path[i]
                    let step = leave.roadClass < arrive.roadClass
                    let turn = normalisedTurn(arrive.bearingOut, leave.bearingIn)
                    let rt = turn > 30 && turn < 150
                    events.append(GiveWayEvent(
                        coordinate: coords[v],
                        flagBits: flags[v],
                        classStep: step,
                        rightTurn: rt
                    ))
                }
            }
        }

        return Route(
            coordinates: geometry,
            distanceMeters: distance,
            travelTimeSeconds: travelTime,
            giveWayCount: events.count,
            giveWayEvents: events,
            isPreview: false
        )
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

    /// Costs added at `vertex` for the manoeuvre `prev` -> `vertex` -> `next`,
    /// split into give-way cost (scaled by aversion) and a flat signal delay.
    private func transitionCosts(from prev: GraphEdge, at vertex: Int, to next: GraphEdge) -> (giveWay: Double, signal: Double) {
        var giveWay = 0.0
        let f = flags[vertex]
        if f & Self.flagGiveWay != 0 { giveWay += Self.nodeGiveWay }
        if f & Self.flagStop != 0 { giveWay += Self.nodeStop }
        if f & Self.flagMiniRoundabout != 0 { giveWay += Self.nodeMiniRoundabout }

        // Joining a higher-class road from a lower-class one: typically yield.
        if next.roadClass < prev.roadClass {
            giveWay += Double(prev.roadClass - next.roadClass) * Self.classStepPenalty
        }

        // UK drives on the left, so a right turn crosses oncoming traffic.
        let turn = normalisedTurn(prev.bearingOut, next.bearingIn)
        if turn > 30, turn < 150 {
            giveWay += Self.rightTurnPenalty
        }

        let signal = (f & Self.flagSignal != 0) ? Self.signalPenalty : 0.0
        return (giveWay, signal)
    }

    private func normalisedTurn(_ b1: Double, _ b2: Double) -> Double {
        var d = b2 - b1
        while d > 180 { d -= 360 }
        while d < -180 { d += 360 }
        return d
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

private func bearing(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
    let lat1 = a.latitude * .pi / 180
    let lat2 = b.latitude * .pi / 180
    let dLon = (b.longitude - a.longitude) * .pi / 180
    let y = sin(dLon) * cos(lat2)
    let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
    return atan2(y, x) * 180 / .pi
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
