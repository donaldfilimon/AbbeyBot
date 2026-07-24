# AbbeyServer dashboard SPA

Read-only React UI over AbbeyServer's JSON API. Built assets land in
`Sources/AbbeyServer/Resources/Public/` and are served at `/dashboard`.

Tabs: Overview, Users, Channels, Messages, Reputation, **Interactions**, Equity
(equity tab shows a synthetic-instrument disclaimer). Teal ops theme. List
views load-more up to server max (`?limit=`, capped at 500).

Leaf `GET /` links to the SPA when `Public/index.html` exists; otherwise it
shows “run `bun run build` in `web/`”.

```bash
cd web
bun install   # or: npm install
bun run build # or: npm run build
bun run test  # or: npm test
bun run dev   # Vite HMR; point fetch at a running AbbeyServer if needed
```

Same-origin when served by AbbeyServer — no CORS config required.
