# Serve Dashboard SPA from AbbeyServer

**Status: shipped** (2026-07-24)

Docker execute-verify (`docker build` + curl `/dashboard`) was **not** run in this environment (Docker unavailable). Image stages were statically reviewed and match the tree below.

Tracker: [`.superpowers/sdd/progress.md`](../../../.superpowers/sdd/progress.md)  
Landed in: `a4590e6` (serve + Bundle.resourceURL fix), `297848d` (gitignore + smoke + docs)

## Goal (met)

Serve the built React dashboard (`web/`) as static assets from `AbbeyServer` at `/dashboard`, one Docker image, no CORS.

## Architecture (as shipped)

Vite `build.outDir` → `Sources/AbbeyServer/Resources/Public/` (gitignored). SPM `.copy("Resources")` packs it. Vapor `FileMiddleware` serves assets; explicit route serves `index.html` at `/dashboard`. Dockerfile: `node:22` web-build → Swift 6.4 build → debian runtime with `AbbeyBot_AbbeyServer.resources`.

## Task checklist

- [x] **Task 1** — Vite outDir → SPM Public (`web/vite.config.ts`)
- [x] **Task 2** — FileMiddleware + `GET /dashboard` (`configure.swift`, `routes.swift`)
- [x] **Task 3** — Dockerfile multi-stage SPA-then-Swift (static review; Docker execute-verify deferred)
- [x] **Task 4** — gitignore Public/; smoke 200/404 (`Scripts/run-server-smoke.sh`)

## Shipped snippets (source of truth)

### Vite (`web/vite.config.ts`)

```typescript
build: {
  outDir: "../Sources/AbbeyServer/Resources/Public",
  emptyOutDir: true,
}
```

### Configure — resources + FileMiddleware

Uses `Bundle.module.resourceURL ?? Bundle.module.bundleURL` (macOS nested Resources vs Linux flat `.resources`):

```swift
let resourcesRoot = (Bundle.module.resourceURL ?? Bundle.module.bundleURL)
    .appendingPathComponent("Resources")
// … viewsDirectory from resourcesRoot/Views …
app.middleware.use(FileMiddleware(publicDirectory: resourcesRoot.appendingPathComponent("Public").path))
```

### Dashboard route

```swift
app.get("dashboard") { req async throws -> Response in
    let publicDir = (Bundle.module.resourceURL ?? Bundle.module.bundleURL)
        .appendingPathComponent("Resources")
        .appendingPathComponent("Public")
    let indexPath = publicDir.appendingPathComponent("index.html").path
    guard FileManager.default.fileExists(atPath: indexPath) else {
        throw Abort(.notFound, reason: "Dashboard not built — run `bun run build` (or npm) in web/ first")
    }
    return try await req.fileio.asyncStreamFile(at: indexPath)
}
```

### Dockerfile resource bundle

Package name is `AbbeyBot`, so the SPM bundle is `AbbeyBot_AbbeyServer.resources` (not `AbbeyServer_AbbeyServer.resources`). Web stage writes to `/Sources/AbbeyServer/Resources/Public`; no placeholder COPY.

### Smoke

`Scripts/run-server-smoke.sh` step 5/8: Leaf `GET /` must 200; `/dashboard` → `dashboard_ok` (200) or `dashboard_skipped` (404 if Public not built). Prefer `bun run build` in `web/`.

## Follow-up (2026-07-24 closeout)

- [x] Wiring `web/` build into Linux CI — `.github/workflows/ci.yml` runs Node 22 + `npm install`/`npm run build` in `web/` before Swift docker build, asserts `Sources/AbbeyServer/Resources/Public/index.html`
- Docker execute-verify (`docker build` + curl `/dashboard`) still unverified locally (Docker CLI unavailable)

## Out of scope (still)

- SPA-internal React changes
- Discord Voice; full bidirectional SwiftData↔Postgres sync
