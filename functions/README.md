# Abbey Functions (Browserbase)

Serverless browser automation via [Browserbase Functions](https://browserbase.com/docs). Bun-managed (the upstream `bb init` hard-requires pnpm; this tree matches its templates).

## Setup

1. Get API key + project ID from https://browserbase.com/settings
2. Copy env and fill in:

```bash
cp .env.example .env
```

3. Install (if needed): `bun install`

## Dev

```bash
bun run dev
# → http://127.0.0.1:14113
```

Invoke the starter (top 3 Hacker News stories):

```bash
curl -X POST http://127.0.0.1:14113/v1/functions/my-function/invoke \
  -H "Content-Type: application/json" \
  -d '{"params": {}}'
```

## Deploy

```bash
bun run deploy
# save the Function ID from the output
bunx bb invoke FUNCTION_ID --params '{}'
```

## Notes

- Not part of `Scripts/verify-all.sh` — optional cloud tooling, separate from the Swift products.
- Credentials live only in `.env` (gitignored). Never commit them.
