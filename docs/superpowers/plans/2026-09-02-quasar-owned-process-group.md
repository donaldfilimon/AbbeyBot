# Quasar Owned Process Group Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Quasar preview stop, replacement, and archive success prove that every process in the preview's privately owned process group has stopped, including signal-ignoring descendants.

**Architecture:** Validate Foundation `Process` launches as a private process group immediately after `run()`, retain that identity with the preview generation, and signal only that validated group through TERM, INT, and KILL. Darwin proves group absence through process-group probes; Linux scans procfs so a live descendant cannot be hidden by a reaped or zombie leader.

**Tech Stack:** Swift 6.4 language mode, Foundation `Process`, Darwin/Glibc/Musl process APIs, Swift Testing, Xcode 27 default toolchain, Swift static Linux SDK, GitHub Actions.

**Spec:** `AGENTS.md` (Quasar lifecycle, verification, and PR workflow), plus the accepted 2026-09-02 portfolio execution contract.

**Integration status:** PR #72 already merged the original regression at merge commit `49aeba7`, and its remote topic branch was deleted. Corrective PR #73 is open from the reused `codex/quasar-force-stop-regression` branch. The final review-fix commit remains local until the controller pushes it; PR #73 must be revalidated at that resulting head before merge.

**Final review-fix status:** The follow-up preserves an explicit `active` / `exitProven` / `ownershipLost` capability state across actor reentrancy, makes the supervisor exit at the cooperative TERM/INT stage without weakening descendant escalation, and brackets every Linux procfs snapshot with two kernel group probes. Mutable probe transitions, real TERM-only versus TERM/INT/KILL signal sequences, and ownership-loss replacement refusal are covered by focused regressions.

## Global Constraints

- Work in the canonical checkout on the existing local `codex/quasar-force-stop-regression` branch; its prior remote branch was deleted after PR #72 merged. Create no additional branch or worktree, and do not push during this implementation task.
- Preserve the merged PR #71 commits, published commit `27f4463`, and PR #72 merge commit `49aeba7`; do not amend, rebase, squash, or force-push them.
- Follow strict TDD: strengthen the regression first, run it against exact-PID shutdown, and record the expected failure before changing production code.
- A negative-PID signal may target only a group validated immediately after launch with `groupID == leaderPID`, both greater than one, and different from AbbeyBot's own group.
- A failed group validation is a failed startup. Never infer ownership later and never signal an unvalidated group.
- Stop, replacement, startup-failure cleanup, and archive-facing shutdown use the same bounded group-exit proof.
- Preserve public commands, wire schemas, `PreviewStatus`, package products, Swift version, dependency graph, platform floors, and unrelated Quasar behavior.
- Use the Xcode default toolchain for Darwin tests; use `ABBEY_PACKAGE_ROLE=server` for non-desktop graphs.
- Resolve every Critical and Important review finding before PR merge.

---

### Task 1: Replace leader-only shutdown with validated owned-group shutdown

**Files:**

- Modify: `Tests/AbbeyQuasarKitTests/QuasarApprovalWorkflowTests.swift`
- Modify: `Sources/AbbeyQuasarKit/QuasarPreviewManager.swift`
- Modify: `Sources/AbbeyQuasarKit/QuasarRegistry.swift`
- Modify: `docs/superpowers/plans/2026-09-02-quasar-owned-process-group.md` only to check completed steps after code and review are finished

**Interfaces:**

- Preserve: `public func start(siteID: String, siteRoot: URL, port: Int) async -> PreviewStatus`
- Preserve: `public func stop(siteID: String) async -> Bool`
- Produce internally: `private struct OwnedProcessGroup: Sendable { let leaderPID: Int32; let groupID: Int32 }`
- Produce internally: each `Entry` retains one `OwnedProcessGroup` with its existing `generationID`.
- Produce internally: a validation helper returns an owned group only when the launched leader is the group leader and the group is not AbbeyBot's group.
- Produce internally: group signaling distinguishes already-absent, delivered, and failed outcomes without treating permission or malformed-state failures as success.
- Produce internally: group liveness distinguishes absent, zombie-only/non-writing, live, and unverifiable states; only kernel-probed group absence satisfies the archive safety contract.

- [x] **Step 1: Strengthen the regression so leader-only SIGKILL is observably wrong**

Replace the existing single-process `previewStopEscalatesWhenGracefulSignalsAreIgnored` fixture with a parent shell and background descendant. Both must ignore TERM and INT, remain in the same process group, write their PIDs to a marker, and append to an activity file until killed. The test must wait for both PIDs, call `stop`, assert both processes no longer exist, then verify the activity file remains unchanged across a bounded post-stop observation. Cleanup must signal only the exact recorded test PIDs if an assertion fails.

The production change this test catches is replacing group signaling with leader-only signaling: the leader exits, `stop` returns, and the descendant continues writing.

- [x] **Step 2: Run the strengthened test against the current implementation and record RED**

Run:

```bash
env -u TOOLCHAINS ABBEY_PACKAGE_ROLE=server \
  /usr/bin/xcrun --toolchain default swift test \
  --scratch-path /private/tmp/abbeybot-quasar-owned-group \
  --filter previewStopEscalatesWhenGracefulSignalsAreIgnored
```

Expected: the test fails because the background descendant remains alive or the activity file continues changing after leader-only shutdown. Record the command, failing assertion, and cleanup result in the task report.

- [x] **Step 3: Validate and retain private process-group ownership**

After `Process.run()`, resolve the leader's process group through the platform API. Construct `OwnedProcessGroup` only if `leaderPID > 1`, `groupID > 1`, `groupID == leaderPID`, and `groupID != getpgrp()` for AbbeyBot. Store it in `Entry` before publishing `.starting` or `.running`.

If validation fails or races with early exit, clear the pipe handler, terminate and reap the exact launched PID without using a negative signal, return `.crashed`, and do not publish the entry as running.

- [x] **Step 4: Implement bounded group signaling and liveness proof**

Replace `killOwnedProcess(_:)` and leader-only exit waiting with one owned-group termination path:

1. If the group is already safely absent, succeed.
2. Send TERM to `-groupID`; wait using the existing bounded polling cadence.
3. If still live, send INT; wait again.
4. If still live, send KILL; wait again.
5. Return true only when the group is safely absent. Linux procfs may classify zombie-only state for diagnostics, but the final negative-PGID existence probe must return `ESRCH` before shutdown succeeds.

Before every signal, recheck the stored numeric invariants and reject AbbeyBot's own group. `ESRCH` means already absent; `EPERM` and all other failures remain fail-closed. Never substitute process-name matching, `pkill`, shell process discovery, or a global registry.

On Darwin, use the validated PGID and group existence probing; success requires `ESRCH` within the bound. On Linux, enumerate numeric `/proc` entries, parse `/proc/<pid>/stat` after the final `)` to obtain state and process-group ID, and classify any matching non-`Z`/non-`X` member as live. A procfs snapshot that appears absent or zombie-only must still be followed by an atomic negative-PGID existence probe; only `ESRCH` is exit proof. If that kernel probe reports a live group, missing or malformed procfs is unverifiable and must fail closed; kernel-reported `ESRCH` remains authoritative even when procfs is unavailable.

Launch the preview command behind a manager-owned supervisor gate. Validate that supervisor's private PGID before releasing the real command, keep the supervisor alive as the group identity anchor throughout TERM/INT/KILL cleanup, and retire the stored signaling capability immediately after atomic group-absence proof. This prevents both pre-validation writes and later numeric-PGID reuse from being signaled as if it were the retired generation.

Use the same `OwnedProcessGroup` in replacement races and generation-mismatch cleanup. An older generation may stop only its own stored group and may not overwrite a newer entry's status.

- [x] **Step 5: Add focused failure-path coverage**

Add table-shaped or narrowly separated tests for:

- cooperative TERM shutdown;
- TERM/INT ignored and KILL required;
- a leader that exits while its descendant remains;
- repeated stop after group absence;
- replacement refusing to launch when the prior group cannot be proven stopped;
- group validation rejecting invalid, non-leader, or self-group identities through a deterministic internal test seam if direct launch behavior cannot construct those states safely;
- Linux procfs missing or malformed through a dependency-injected liveness reader rather than mutating the host `/proc` filesystem.

Each test must assert externally visible stop/start status or process liveness. Do not add source-text assertions or tests that only exercise a mock.

- [x] **Step 6: Run focused GREEN verification**

Run the primary test 10 consecutive times, recording every exit status, then run the complete target:

```bash
env -u TOOLCHAINS ABBEY_PACKAGE_ROLE=server \
  /usr/bin/xcrun --toolchain default swift test \
  --scratch-path /private/tmp/abbeybot-quasar-owned-group \
  --filter AbbeyQuasarKitTests
```

Also run a Darwin probe proving the launched leader owns a private PGID and the leader plus descendant are both absent before `stop` returns.

- [x] **Step 7: Run platform and repository gates**

Run, preserving their real exit codes:

```bash
env -u TOOLCHAINS bash Scripts/check-server-snapshot.sh
env -u TOOLCHAINS bash Scripts/check-server-linux.sh
env -u TOOLCHAINS bash Scripts/check-static-security.sh
git diff --check
env -u TOOLCHAINS bash Scripts/verify-all.sh
```

The Linux gate must compile every `getpgid`, `getpgrp`, group-signal, errno, and procfs branch for Musl. If a pre-existing unrelated full Linux blocker remains, record its exact first failure and retain separate compile proof for the lifecycle code; do not relabel the full gate green.

- [x] **Step 8: Self-review and commit**

Review the entire branch range from `origin/main` through the working tree for signal-scope safety, PID/PGID reuse, descendant liveness, generation replacement, missing procfs, zombie behavior, cleanup leaks, and public-interface drift.

Commit the production correction and strengthened tests without rewriting `27f4463`:

```bash
git add Sources/AbbeyQuasarKit/QuasarPreviewManager.swift \
  Sources/AbbeyQuasarKit/QuasarRegistry.swift \
  Tests/AbbeyQuasarKitTests/QuasarApprovalWorkflowTests.swift \
  docs/superpowers/plans/2026-09-02-quasar-owned-process-group.md
git commit -m "fix(quasar): terminate owned preview process groups"
```

- [ ] **Step 9: Independent review, PR integration, and branch closeout**

Independently review `49aeba7..HEAD`. Required questions are whether any negative signal can reach AbbeyBot or an unrelated group, whether ownership is validated before publication, whether every cleanup/replacement path uses group proof, whether a descendant can survive a zombie or reaped leader, and whether the regression truly contains two processes.

PR #72 already merged at `49aeba7` with the original regression and its remote topic branch was deleted. Corrective PR #73 is now open from the reused `codex/quasar-force-stop-regression` branch. Resolve all Critical and Important findings, push the final review-fix commit normally, and require every hosted check on PR #73's resulting head. Merge it normally, wait for the post-merge `main` workflow, fast-forward the canonical `main`, and delete only the reused corrective branch locally and remotely.

After a separately verified branch-ref archive and fresh ancestry checks, delete the three stale remote `cursor/*` branches named in the portfolio plan. Finish with clean local and remote `main`, one worktree, and no unique topic work.
