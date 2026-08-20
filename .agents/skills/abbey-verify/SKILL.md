---
name: abbey-verify
description: Verify and prepare an AbbeyBot change for review using the repository's authoritative gates and protected-branch workflow.
---

# AbbeyBot Verify and Ship

Use this workflow after completing a coherent AbbeyBot implementation slice.

1. Read the root `AGENTS.md` Verify section and the narrow-smoke guidance for the surfaces changed.
2. Run `git status --short --branch`; preserve unrelated work and stop if another writer owns an overlapping file.
3. Confirm changes are on a review branch (`codex/*` or `cursor/*`), never a direct commit on `main`.
4. Run `bash Scripts/check-static-security.sh`.
5. During iteration, run the narrowest relevant smoke or filtered Swift test. Before declaring the slice shippable, run `bash Scripts/verify-all.sh`.
6. Inspect `git diff --check`, `git diff --stat`, and the complete diff. Correct claim drift in `AGENTS.md`, `AGENTS.md`, README, and `tasks/` only when executable evidence supports it.
7. Stage explicit paths; do not stage `.env`, tokens, build products, hooks, or unrelated dirty files.
8. Commit with a focused action-oriented message under 72 characters and push the review branch without force.
9. Create or update a pull request into `main`. Report local gate results separately from GitHub Actions, which may be unavailable because of account billing/quota.
10. After merge, fetch/prune, check out `main`, fast-forward from `origin/main`, and delete only clean merged branches/worktrees.

Never claim live Discord, Twitch callback verification, Postgres behavior, or Foundation Models availability from mocks or SQLite-only tests.
