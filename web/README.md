# AbbeyServer dashboard SPA

Read-only React UI over AbbeyServer's JSON API. Built assets land in
`Sources/AbbeyServer/Resources/Public/` and are served at `/dashboard`.

```bash
cd web
bun install   # or: npm install
bun run build # or: npm run build
bun run test  # or: npm test
bun run dev   # Vite HMR; point fetch at a running AbbeyServer if needed
```

Same-origin when served by AbbeyServer — no CORS config required.
