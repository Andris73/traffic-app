# Priority Traffic

A turn-by-turn iOS navigation app that routes for **priority / right-of-way**.
Where a normal app routes for shortest time, Priority Traffic prefers roads
where you keep priority and have to *give way* as rarely as possible (UK
"give way to the right"), trading a little distance for a smoother, less
stop-start drive.

Native SwiftUI, built unsigned on GitHub Actions and distributed by sideloading
through the [Andris73 AltStore source](https://github.com/Andris73/altstore).

## Status

**Phase 0 — distribution pipeline.** Minimal app: a MapKit map centred on your
location, proving the build → IPA → AltStore → on-device install loop works
before any routing logic lands.

Roadmap:

1. **Done** — distribution pipeline + map + place search
2. **Done** — on-device A* routing over a bundled OSM graph (Cambridge area)
3. **Done** — downloadable area graphs (settings) + navigation follow + 5-minute reroute
4. **Done** — give-way cost model: explicit OSM node flags
   (give_way / stop / signals / mini-roundabout), road-class step-up at
   junctions, right-turn-across-oncoming (UK left-side), with a tunable
   aversion slider (0–3×, persisted) in Settings
5. **Done** — **user-defined areas built on-device.** Pan the map to your area
   (e.g. Cambridgeshire + Suffolk + Essex), name it, tap Build. The app calls
   Overpass, contracts the OSM graph in Swift, saves it locally, and switches
   to it. Persists across launches.
6. **Next** — historical time-of-day traffic profiles seeded from UK
   National Highways WebTRIS (free, OGL), then an optional opt-in live overlay
   via TomTom or HERE free tier (per the traffic research). Avoid Google/
   Mapbox traffic — their licences forbid feeding a custom router.
   **Weighting: traffic counts much more than give-way aversion** — users hate
   traffic more than giving way, so the ideal route is low-traffic first, then
   as few give-ways as possible. Traffic dominates the cost; give-way penalties
   stay a secondary refinement under the aversion slider.

## Build

CI (`.github/workflows/build.yml`) runs on every push and is manually runnable
(`workflow_dispatch`). It archives unsigned, zips a `Payload/` into
`PriorityTraffic.ipa`, uploads it as a build artifact, and (on `main`/`master`)
publishes to the AltStore source.

## Distribution setup (one-time)

The build publishes to the central `Andris73/altstore` repo. All it needs is a
`ALTSTORE_TOKEN` secret on this repo — a PAT with write access to
`Andris73/altstore`. CI then syncs the app metadata
([`altstore/prioritytraffic.json`](altstore/prioritytraffic.json)) into the
central repo's `tools/apps/`, commits the IPA and icon, and updates `apps.json`,
so the first publish bootstraps everything with no manual central-repo edit.

Until `ALTSTORE_TOKEN` is set the publish step skips cleanly and the IPA is still
available as a build artifact, so the pipeline is testable immediately. App
metadata (name, subtitle, description) is edited here in
`altstore/prioritytraffic.json`.

## Targets

- Deployment target: **iOS 18.0** (runs on iOS 26 devices; bump the CI Xcode to
  26 if iOS 26-only APIs are ever needed).
- Bundle ID: `com.prioritytraffic.app`
