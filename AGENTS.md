# AGENTS.md — AbbeyBot

Unified desktop Abbey bot at `~/Desktop/AbbeyBot`.

## Stack

- Swift 6.4 language mode, Xcode default toolchain (`unset TOOLCHAINS`)
- `AbbeyCore` library + `AbbeyBotApp` SwiftUI executable
- DiscordBM `from: "1.16.0"` (gateway + REST; Voice deferred)
- SwiftData local store (no Vapor/Postgres in v1)

## Verify

```bash
unset TOOLCHAINS
bash Scripts/run-smoke.sh
```

Build path is `${TMPDIR}/AbbeyBot.build` to avoid Desktop/iCloud xattr codesign failures.

## Discord live path

1. Developer Portal bot + Message Content intent
2. Discord tab → paste token (Keychain) → Connect
3. Optional: set Dev guild ID → Register slash commands
4. Settings operating mode `liveDiscord` + auto-connect optional

## Phase 2 (not started)

Vapor HTTP, Fluent/Postgres, React dashboard, Docker/systemd headless deploy.
