# AbbeyBot

Unified Swift 6.4 desktop bot for Abbey: **SwiftUI + SwiftData + DiscordBM v1.16+**.

| Layer | Tech |
|-------|------|
| App | `AbbeyBotApp` — macOS SwiftUI |
| Core | `AbbeyCore` — brain, personas, inference, Discord bridge |
| Discord | DiscordBM gateway + REST (Voice deferred) |
| Store | Local SwiftData (no Vapor/Postgres in v1) |

## Run

```bash
unset TOOLCHAINS   # use Xcode toolchain — not DEVELOPMENT-SNAPSHOT
cd ~/Desktop/AbbeyBot
swift run
```

Or:

```bash
open Package.swift   # Xcode ▸ Run
```

## Verify

```bash
bash Scripts/run-smoke.sh
```

## Discord

1. Create a bot in the Discord Developer Portal; enable **Message Content** intent.
2. Paste the token in the **Discord** sidebar tab (stored in Keychain) or export `DISCORD_BOT_TOKEN`.
3. Connect → Register slash commands (optionally set a dev guild ID for instant sync).
4. Set operating mode to `liveDiscord` in Settings.

Slash commands: `ask`, `rep`, `remember`, `forget`, `context`, `persona`.

## Layout

```
Sources/AbbeyCore/     # library (Models, Engine, Inference, Personas, Equity, Discord)
Sources/AbbeyBotApp/   # @main SwiftUI executable
Tests/AbbeyCoreTests/
```

## Phase 2 (not in this Desktop ship)

Vapor HTTP, Fluent/Postgres, React dashboard, Docker/systemd headless deploy.

## Next steps (operator)

1. `unset TOOLCHAINS && swift run` (or Xcode open `Package.swift`)
2. Discord tab → bot token → Connect → Register slash commands (dev guild recommended)
3. Invite the bot to a test guild with message content intent enabled
4. When ready for a remote: `git remote add` + first commit (repo is initialized locally on `main`)
