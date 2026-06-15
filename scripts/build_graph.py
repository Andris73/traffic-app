#!/usr/bin/env python3
"""Build a compact on-device routing graph from OSM (Overpass) for a bbox.

Fetches the drivable highway network, contracts shape points so vertices are
only junctions/endpoints (keeping geometry as a polyline per edge), tags
give-way relevant nodes, and writes a JSON graph the app bundles.

Output schema (arrays, not objects, to keep it small):
  {
    "bbox": [s, w, n, e],
    "vertices": [[lat, lon, flags], ...],         # flags bitmask, see FLAG_*
    "edges": [[u, v, length_m, class, oneway, [lat,lon,lat,lon,...]], ...]
  }
  oneway: 0 both ways, 1 u->v only, -1 v->u only
  class:  0 motorway .. 8 service (lower = higher priority); links share parent
"""
import json
import math
import os
import urllib.parse
import urllib.request

# Cambridge area: Cambridge / Newmarket / Haverhill / Saffron Walden
BBOX = (52.00, -0.05, 52.35, 0.55)  # south, west, north, east

OVERPASS_ENDPOINTS = [
    "https://overpass.kumi.systems/api/interpreter",
    "https://overpass-api.de/api/interpreter",
    "https://maps.mail.ru/osm/tools/overpass/api/interpreter",
]

# Service roads (driveways/parking aisles) are skipped: they bloat the graph and
# aren't needed for through-routing.
DRIVABLE = (
    "motorway|trunk|primary|secondary|tertiary|unclassified|residential|"
    "living_street|motorway_link|trunk_link|primary_link|"
    "secondary_link|tertiary_link"
)

CLASS_RANK = {
    "motorway": 0, "trunk": 1, "primary": 2, "secondary": 3, "tertiary": 4,
    "unclassified": 5, "residential": 6, "living_street": 7, "service": 8,
    "motorway_link": 0, "trunk_link": 1, "primary_link": 2,
    "secondary_link": 3, "tertiary_link": 4,
}

FLAG_GIVE_WAY = 1
FLAG_STOP = 2
FLAG_SIGNAL = 4
FLAG_ROUNDABOUT = 8


def overpass_query():
    s, w, n, e = BBOX
    return f"""
[out:json][timeout:300];
(
  way["highway"~"^({DRIVABLE})$"]({s},{w},{n},{e});
);
(._;>;);
out body;
"""


def fetch():
    body = urllib.parse.urlencode({"data": overpass_query()}).encode()
    last_error = None
    for endpoint in OVERPASS_ENDPOINTS:
        try:
            req = urllib.request.Request(
                endpoint,
                data=body,
                headers={
                    "User-Agent": "priority-traffic-graph-builder/1.0",
                    "Content-Type": "application/x-www-form-urlencoded",
                    "Accept": "application/json",
                },
            )
            print(f"querying {endpoint} ...")
            data = urllib.request.urlopen(req, timeout=320).read()
            return json.loads(data)
        except Exception as exc:  # noqa: BLE001 - try the next mirror
            print(f"  {endpoint} failed: {exc}")
            last_error = exc
    raise SystemExit(f"all Overpass endpoints failed: {last_error}")


def haversine(a, b):
    r = 6371000.0
    lat1, lon1 = math.radians(a[0]), math.radians(a[1])
    lat2, lon2 = math.radians(b[0]), math.radians(b[1])
    dlat, dlon = lat2 - lat1, lon2 - lon1
    h = math.sin(dlat / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin(dlon / 2) ** 2
    return 2 * r * math.asin(math.sqrt(h))


def main():
    raw = fetch()
    elements = raw["elements"]

    nodes = {}
    ways = []
    for el in elements:
        if el["type"] == "node":
            nodes[el["id"]] = (el["lat"], el["lon"], el.get("tags", {}))
        elif el["type"] == "way" and el.get("nodes"):
            ways.append((el.get("tags", {}), el["nodes"]))

    # Node flags + how many ways use each node (to find junctions).
    usage = {}
    for _, nds in ways:
        for nid in nds:
            usage[nid] = usage.get(nid, 0) + 1

    def node_flags(nid):
        tags = nodes[nid][2]
        f = 0
        hw = tags.get("highway")
        if hw == "give_way":
            f |= FLAG_GIVE_WAY
        if hw == "stop":
            f |= FLAG_STOP
        if hw == "traffic_signals":
            f |= FLAG_SIGNAL
        if hw == "mini_roundabout":
            f |= FLAG_ROUNDABOUT
        return f

    # A node is a graph vertex if it joins >1 way, is a way endpoint, or carries
    # a give-way relevant tag.
    is_vertex = {}
    for _, nds in ways:
        for i, nid in enumerate(nds):
            endpoint = i == 0 or i == len(nds) - 1
            if endpoint or usage.get(nid, 0) > 1 or node_flags(nid):
                is_vertex[nid] = True

    vindex = {}
    vertices = []

    def vertex_id(nid):
        if nid not in vindex:
            lat, lon, _ = nodes[nid]
            f = node_flags(nid)
            vindex[nid] = len(vertices)
            vertices.append([round(lat, 6), round(lon, 6), f])
        return vindex[nid]

    edges = []
    for tags, nds in ways:
        hw = tags.get("highway")
        cls = CLASS_RANK.get(hw, 8)
        roundabout = tags.get("junction") in ("roundabout", "circular")
        ow = tags.get("oneway", "")
        if roundabout or ow in ("yes", "true", "1"):
            oneway = 1
        elif ow == "-1":
            oneway = -1
        else:
            oneway = 0

        # Walk the way, cutting a new edge at each vertex node.
        seg_start = nds[0]
        coords = [(nodes[nds[0]][0], nodes[nds[0]][1])]
        length = 0.0
        for prev, cur in zip(nds, nds[1:]):
            p = (nodes[prev][0], nodes[prev][1])
            c = (nodes[cur][0], nodes[cur][1])
            length += haversine(p, c)
            coords.append(c)
            if is_vertex.get(cur):
                if cur != seg_start and length > 0:
                    u, v = vertex_id(seg_start), vertex_id(cur)
                    flat = [round(x, 6) for pt in coords for x in pt]
                    edges.append([u, v, round(length, 1), cls, oneway, flat])
                seg_start = cur
                coords = [c]
                length = 0.0

    out = {"bbox": list(BBOX), "vertices": vertices, "edges": edges}
    dest = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                        "PriorityTraffic", "Resources", "graph-cambridge.json")
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    with open(dest, "w") as f:
        json.dump(out, f, separators=(",", ":"))
    size = os.path.getsize(dest)
    flagged = sum(1 for v in vertices if v[2])
    print(f"vertices={len(vertices)} edges={len(edges)} flagged_nodes={flagged} "
          f"size={size/1e6:.2f}MB -> {dest}")


if __name__ == "__main__":
    main()
