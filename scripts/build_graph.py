#!/usr/bin/env python3
"""Build compact on-device routing graphs from OSM (Overpass) for named areas.

For each area it fetches the drivable highway network, contracts shape points so
vertices are only junctions/endpoints (keeping geometry as a polyline per edge),
tags give-way relevant nodes, and writes graphs/<id>.json plus a manifest the app
reads to offer downloads. The default area is also copied into the app bundle.

Graph schema (arrays, not objects, to keep it small):
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

RAW_BASE = "https://raw.githubusercontent.com/Andris73/traffic-app/master/graphs"

# id: (display name, (south, west, north, east), bundled-as-default?)
AREAS = {
    "cambridge-city": ("Cambridge (city)", (52.16, 0.06, 52.25, 0.20), False),
    "cambridge": ("Cambridge area", (52.00, -0.05, 52.35, 0.55), True),
    "oxford": ("Oxford", (51.68, -1.34, 51.83, -1.15), False),
}

DEFAULT_AREA = "cambridge"

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

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GRAPHS_DIR = os.path.join(REPO_ROOT, "graphs")
BUNDLE_PATH = os.path.join(REPO_ROOT, "PriorityTraffic", "Resources", "graph-cambridge.json")


def overpass_query(bbox):
    s, w, n, e = bbox
    return f"""
[out:json][timeout:300];
(
  way["highway"~"^({DRIVABLE})$"]({s},{w},{n},{e});
);
(._;>;);
out body;
"""


def fetch(query):
    body = urllib.parse.urlencode({"data": query}).encode()
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
            print(f"  querying {endpoint} ...")
            data = urllib.request.urlopen(req, timeout=320).read()
            return json.loads(data)
        except Exception as exc:  # noqa: BLE001 - try the next mirror
            print(f"    {endpoint} failed: {exc}")
            last_error = exc
    raise SystemExit(f"all Overpass endpoints failed: {last_error}")


def haversine(a, b):
    r = 6371000.0
    lat1, lon1 = math.radians(a[0]), math.radians(a[1])
    lat2, lon2 = math.radians(b[0]), math.radians(b[1])
    dlat, dlon = lat2 - lat1, lon2 - lon1
    h = math.sin(dlat / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin(dlon / 2) ** 2
    return 2 * r * math.asin(math.sqrt(h))


def build_area(area_id, bbox):
    raw = fetch(overpass_query(bbox))
    elements = raw["elements"]

    nodes = {}
    ways = []
    for el in elements:
        if el["type"] == "node":
            nodes[el["id"]] = (el["lat"], el["lon"], el.get("tags", {}))
        elif el["type"] == "way" and el.get("nodes"):
            ways.append((el.get("tags", {}), el["nodes"]))

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
            vindex[nid] = len(vertices)
            vertices.append([round(lat, 6), round(lon, 6), node_flags(nid)])
        return vindex[nid]

    edges = []
    for tags, nds in ways:
        cls = CLASS_RANK.get(tags.get("highway"), 8)
        roundabout = tags.get("junction") in ("roundabout", "circular")
        ow = tags.get("oneway", "")
        if roundabout or ow in ("yes", "true", "1"):
            oneway = 1
        elif ow == "-1":
            oneway = -1
        else:
            oneway = 0

        seg_start = nds[0]
        coords = [(nodes[nds[0]][0], nodes[nds[0]][1])]
        length = 0.0
        for prev, cur in zip(nds, nds[1:]):
            length += haversine((nodes[prev][0], nodes[prev][1]), (nodes[cur][0], nodes[cur][1]))
            coords.append((nodes[cur][0], nodes[cur][1]))
            if is_vertex.get(cur):
                if cur != seg_start and length > 0:
                    flat = [round(x, 6) for pt in coords for x in pt]
                    edges.append([vertex_id(seg_start), vertex_id(cur), round(length, 1), cls, oneway, flat])
                seg_start = cur
                coords = [(nodes[cur][0], nodes[cur][1])]
                length = 0.0

    out = {"bbox": list(bbox), "vertices": vertices, "edges": edges}
    os.makedirs(GRAPHS_DIR, exist_ok=True)
    path = os.path.join(GRAPHS_DIR, f"{area_id}.json")
    with open(path, "w") as f:
        json.dump(out, f, separators=(",", ":"))
    return path, len(vertices), len(edges), os.path.getsize(path)


def main():
    manifest = {"areas": []}
    for area_id, (name, bbox, _bundled) in AREAS.items():
        print(f"{area_id}: {name}")
        path = os.path.join(GRAPHS_DIR, f"{area_id}.json")
        if os.path.exists(path):
            size = os.path.getsize(path)
            print(f"  exists, skipping fetch (size={size/1e6:.2f}MB)")
        else:
            path, nv, ne, size = build_area(area_id, bbox)
            print(f"  vertices={nv} edges={ne} size={size/1e6:.2f}MB")
        manifest["areas"].append({
            "id": area_id,
            "name": name,
            "bbox": list(bbox),
            "sizeBytes": size,
            "url": f"{RAW_BASE}/{area_id}.json",
            "bundled": area_id == DEFAULT_AREA,
        })

    with open(os.path.join(GRAPHS_DIR, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=2)

    default_src = os.path.join(GRAPHS_DIR, f"{DEFAULT_AREA}.json")
    os.makedirs(os.path.dirname(BUNDLE_PATH), exist_ok=True)
    with open(default_src, "rb") as s, open(BUNDLE_PATH, "wb") as d:
        d.write(s.read())
    print(f"manifest: {len(manifest['areas'])} areas; bundled default '{DEFAULT_AREA}'")


if __name__ == "__main__":
    main()
