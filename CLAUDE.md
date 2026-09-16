# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Read [AGENTS.md](./AGENTS.md) first. It is the canonical instruction file for this
Swift AbbeyBot checkout (not the separate Rust `abbey-bot` repository) and owns
package boundaries, toolchain selection, gate commands, focused-test invocations,
behavioral/safety boundaries, and the review-branch workflow. Keep this file a
routing index, not a second copy of those rules. A duplicated gate list drifts.

## Where to look

| Question | Authority |
|---|---|
| Target graph, `ABBEY_PACKAGE_ROLE` / `ABBEY_NATIVE_MEDIA`, entry dispatch | AGENTS.md → Package Boundaries; `Package.swift`, `Sources/AbbeyEntry/main.swift` |
| Toolchain, `TOOLCHAINS`, build paths, run wrappers | AGENTS.md → Toolchain and Launch; `Scripts/run*.sh` |
| Gates, smokes, single filtered test, `web/` and `functions/` commands | AGENTS.md → Verify; `Scripts/verify-all.sh` is the script of record |
| Auth policy, sync contracts, Quasar approval, claim limits | AGENTS.md → Behavioral Boundaries |
| Branching, staging, drift-checking the agent mirrors | AGENTS.md → Workflow |
| What is actually shipped vs. implemented-but-unverified | `README.md` → Status; `tasks/goals.md`, `tasks/todo.md` |
| Voice/video architecture and its evidence boundary | `docs/discord-voice-architecture.md`, `docs/native-media-dependencies.md` |
| Deployment and image consumption | `deploy/production/README.md`; image gate `Scripts/check-release-container.sh` and `.github/workflows/release-images.yml` (AGENTS.md → Additional Gates) |

## Claude-specific

- Ship workflow: invoke the `abbey-verify` skill (`.claude/skills/abbey-verify/SKILL.md`).
  It encodes the review-branch, narrow-smoke-then-`verify-all`, explicit-path-staging,
  and PR sequence.
- Convention changes must move together across `.claude/skills/abbey-verify/SKILL.md`,
  `.agents/skills/abbey-verify/SKILL.md`, `.cursor/agents/abbey.md`, and
  `.codex/agents/abbey.toml`. Check those four for drift whenever a gate or toolchain
  rule changes here.
- Local green is never live-service evidence. Do not upgrade a passing smoke into a
  claim about Discord audio, Twitch, Postgres, or a deployed host.
