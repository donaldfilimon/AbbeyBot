# Product integration evidence: 2026-09-16

Full product completion remains open. This entry re-certifies the current
`main` with every gate that runs on this machine and re-measures each external
blocker. It supersedes the September 8 ledger's current-status claims; that
file's dated results stay historical evidence. Nothing here is production
deployment, live-service acceptance or media qualification.

## Candidate

Canonical `main` and `origin/main` were observed equal at
`2143a6424f3520e8f31b6f4519455563f1f6439d` (merge of PR #94), seven pull
requests past the September 8 candidate `a9b6c17` (#88–#94). Its tree is
byte-identical to the PR #94 head that the ordinary gate certified (`git diff
2143a64^2 2143a64` is empty). One local worktree, `main` the only local branch.

## Local gates on the exact tree

Every exit code below was read from the gate's own log file, not from a pipe.

| Gate | Command | Result |
| --- | --- | --- |
| Ordinary release gate | `bash Scripts/verify-all.sh` on the PR #94 tip | Exit 0, `VERIFY-ALL GREEN`: static/security, package graphs, signed knowledge snapshot, web smoke, full desktop suite (520 tests / 49 suites), signed desktop launch, server smoke (SQLite) and CLI smoke. |
| Native media gate | `bash Scripts/run-native-media-smoke.sh` | Exit 0, `NATIVE_MEDIA_SMOKE_GREEN`: fresh pinned bootstrap (libdave macOS ARM64 BoringSSL zip, opus 1.6.1, libsodium 1.0.22, all download-verified), 102 tests / 9 suites in debug and again in release, rerun safety, runtime output-secrecy probe, static/security. |
| Deployment control flow | `bash deploy/production/tests/run.sh` | Exit 0, 30 tests, `OK`. Local control-flow coverage with test doubles, not a host. All five deployment shell scripts pass `bash -n`; `backup-format.py` parses. |
| Server snapshot gate | `bash Scripts/check-server-snapshot.sh` | Exit 0, `SERVER_SNAPSHOT_GREEN (main-snapshot-2026-08-21)`: native-host nightly build, then Core 520 / 49 suites, Quasar 84 / 12, CLI 30 / 3, ServerKit 122 / 12, Server 34 / 1. |
| Linux cross-compile | `bash Scripts/check-server-linux.sh` with `ABBEY_LINUX_TOOLCHAIN=main-snapshot-2026-08-21` and the matching `ABBEY_LINUX_SDK_BUNDLE` | Exit 0, `SERVER_LINUX_GREEN`: resolve, server-graph product build against the 2026-08-21 static-Linux SDK (musl, x86_64), and the glibc-divergence lint. Compile-only; no tests. |

The Linux gate first failed twice before compiling anything: with two
static-Linux SDK bundles installed (2026-07-11 and 2026-08-21) SwiftPM rejected
both a triple-only and a bundle-only `--swift-sdk` query as ambiguous. The
script now selects the SDK by bundle name plus `--triple`, the form SwiftPM's
own error recommends; the rerun with that change is the green row above. The
single-SDK default path was not re-exercised (removing an SDK is an operator
choice). This gate is compile-only against musl; it runs no tests and is not
the glibc CI image, as its header states.

## Hosted evidence: none for this candidate

No Abbey CI or release workflow has run since the September 8 candidate. Every
push since (measured with `gh run list` on 2026-09-16) records a run named
`BuildFailed` with conclusion `startup_failure`, zero jobs and an
`updated_at` equal to its `run_started_at`. The three workflow files are
unchanged since 2026-09-06 (the September 8 runs passed on them) and
`actionlint` reports nothing, so this is not a workflow defect. It matches the
account billing lock recorded machine-wide since 2026-09-08 (inference from the
signature, not a billing-API reading; the token lacks that scope). Consequences:

- There are no hosted Linux CI results for `2143a64`.
- No release images exist past `a9b6c17`. The last published candidates remain
  the September 8 digests
  `ghcr.io/donaldfilimon/abbeybot@sha256:6a7d9ea4…` and
  `ghcr.io/donaldfilimon/abbeybot-caddy@sha256:31698e48…`, and they do not
  contain PRs #88–#94.
- Nothing on this machine can build the image: no docker, podman, colima or
  OrbStack is installed.

## Deployment prerequisites, re-measured 2026-09-16 13:1x EDT

| Prerequisite | Command | Observation |
| --- | --- | --- |
| Host SSH | `ssh -o BatchMode=yes root@2.25.160.8 true` | `Permission denied (publickey,password)`. The deployment key is still not attached to VPS 1955556. |
| Domain | `dig +short xfoss.dev A`, `dig +short api.xfoss.dev A`, `dig +short NS xfoss.dev` | All empty: the domain is neither registered nor delegated. |
| Registry read | `gh auth status` | Token scopes are `delete_repo, gist, read:org, repo, workflow`; no `read:packages`, so GHCR digests and labels cannot be inspected. |
| Hosted CI/release | `gh run list` | Locked as described above. |
| R2, restic, provider credentials | not measured | Still unconfigured; values must never enter this ledger. |

No purchase, registration, key attachment, host change or credential
configuration was performed.

## Completion audit

| Required outcome | Status at `2143a64` |
| --- | --- |
| Clean canonical main equals remote main | Complete: `main` = `origin/main` = `2143a64`, one worktree, no stray branches. |
| Final ordinary and native gates | Complete locally on the exact tree (table above). |
| Commit-specific Linux CI and release images | Open: hosted runs cannot start; local musl cross-compile is the only Linux evidence and is compile-only. |
| Immutable GHCR and running-image identity | Open: needs `read:packages`, then a release run for this candidate. |
| Hostinger health and persistent restart | Open: SSH still denied. |
| Cloudflare DNS and public TLS | Open: domain unregistered. |
| R2 backup and restore | Open: bucket and credentials not enabled. |
| Real-model Quasar lifecycle | Open: needs a deployed host. |
| Discord proposal authorization | Open: needs the isolated guild. |
| Twitch Helix/EventSub | Open: needs public HTTPS. |
| Discord audio, camera and Go Live | Open: needs consented live qualification; see the voice and video goals. |

Operator actions that unblock the next slice, in order: clear the GitHub
billing lock; grant the CLI token `read:packages`; attach the deployment public
key to VPS 1955556; register and delegate `xfoss.dev`; enable R2 and configure
the private credentials. After the first three, the next engineering slice is
registry inspection of a fresh release run followed by the guarded host
bootstrap in `deploy/production/README.md`.
