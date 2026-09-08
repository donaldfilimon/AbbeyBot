# Product integration evidence: 2026-09-08

Full product completion remains open. Repository integration, deployment, live
service acceptance, and participant-consented media qualification have separate
acceptance requirements. This entry supersedes undated current-status claims in
the older Quasar ledger; dated failures remain historical evidence.

## Repository and local verification

- The original clean checkout at `efb5047` was strictly fast-forwarded to the
  requested baseline `3a762cbfb76522e22931c566bc6cb7fa561df9a9`. No synchronization
  commit or force push was used. The merged routing-index branch was removed.
- The WebKit navigation delegate correction and regression test merged through
  [PR #83](https://github.com/donaldfilimon/AbbeyBot/pull/83) at `ebb349a8`.
- The native test compiler workaround and binary DAVE sequence test barrier
  merged through [PR #84](https://github.com/donaldfilimon/AbbeyBot/pull/84) at
  `77ea1c0f4fbc823c2247d4a530a789752a4600bd`. Canonical `main` was fast-forwarded
  there and the merged local branch removed. Its tree equals PR head `c6cab92`.
- A subsequent ordinary gate failed the Quasar active-preview replacement
  fixture. Its unconditional readiness probe raced child startup. The fixture
  now waits for a marker from each child; production process ownership checks
  are unchanged. [PR #85](https://github.com/donaldfilimon/AbbeyBot/pull/85), head
  `f287cdd6d6f14dd688ef014e33793b3378a8b859`, is awaiting hosted checks/integration
  at this observation.

| Verification | Observed result and scope |
| --- | --- |
| `Scripts/verify-all.sh` at `f287cdd` | Exit 0, `VERIFY-ALL GREEN`: static/security, package graphs, signed knowledge snapshot, 17 web tests/build, full ordinary Swift tests, signed desktop launch, server and CLI smokes. Server smoke used SQLite. |
| Focused active-preview replacement at `f287cdd` | Passed with both actual child commands started and retired. |
| `deploy/production/tests/run.sh` on the PR #84 tree | All 30 tests passed; deployment shell scripts also passed `bash -n`. This is local control-flow coverage with test doubles. |
| Native gate with compiler workaround `83ba63d` | `NATIVE_MEDIA_SMOKE_GREEN`, including fresh pinned bootstrap, debug/release native suites, output-secrecy checks and static/security. The release suite passed 102 tests in 9 suites. Later Core/Quasar fixture changes are not an additional native gate run. |
| Fresh ordinary and native gates at `86738fc` | Both exited 0: `VERIFY-ALL GREEN` and `NATIVE_MEDIA_SMOKE_GREEN`. Native debug and release each passed 102 tests in 9 suites; fresh bootstrap, versions, rerun safety and runtime output-secrecy checks passed. This candidate includes the PR #85 fixture correction and the initial documentation update. |
| Linux CI at merged `77ea1c0` | [Run 34214616421](https://github.com/donaldfilimon/AbbeyBot/actions/runs/34214616421) passed. |
| PR #84 container gate | [Run 34213985781](https://github.com/donaldfilimon/AbbeyBot/actions/runs/34213985781) passed. This is the PR image test, not proof of production deployment. |
| Release publication at `77ea1c0` | [Run 34214616577](https://github.com/donaldfilimon/AbbeyBot/actions/runs/34214616577) was still running at this observation. |

## Deployment prerequisites

Hostinger's API re-confirmed existing VPS `srv1955556.hstgr.cloud` (ID `1955556`)
running Ubuntu 26.04 LTS at `2.25.160.8`, with 8 CPUs, 32 GiB RAM and 400 GiB disk.
SSH to `root@2.25.160.8` still returns `Permission denied (publickey,password)`.
The deployment public key must be attached through Hostinger management before
host modification, as required by the approved plan. Host processes, Docker,
volumes, firewall behavior and persistence have not been inspected over SSH.

Hostinger reports `xfoss.dev` available for registration. Neither `xfoss.dev` nor
`api.xfoss.dev` returned a DNS address. Registration through the existing free
entitlement, authoritative Cloudflare delegation and public TLS remain open. No
purchase, domain delegation, host installation or restart was performed.

The current GitHub credential has no `read:packages` scope. Direct verification
of private GHCR package visibility, registry digests and revision labels remains
blocked. The original plan's baseline image references are retained below as
recorded release references, not newly inspected or deployed images:

```text
ghcr.io/donaldfilimon/abbeybot@sha256:5f24afdffbf594dbfcc0fae310ea08a582230d6ffa63d4c8d88625bf58d72491
ghcr.io/donaldfilimon/abbeybot-caddy@sha256:1b73a5779584de2180f4e8c5c8cfadfe644326e19a3cb84b3a23f9e863c24d7b
```

These belong to baseline `3a762cb`; later main commits require a fresh release
identity decision and registry inspection before deployment. Inference, Swift
Discord application, operator/Quasar, database, DNS, R2 and restic credentials
must be configured privately. Their values must never enter this ledger.

## Completion audit and next evidence

| Required outcome | Remaining evidence |
| --- | --- |
| Clean canonical main equals live remote main | Integrate remaining review branches; fetch, strict fast-forward and verify clean status and exact SHA. |
| Final ordinary and native gates | Both gates passed at `86738fc` as recorded above. Reconcile that exact tested source/test tree with the eventual merged candidate. |
| Commit-specific Linux CI and release images | Await remaining workflows and verify the final main commit's results. |
| Immutable GHCR and running-image identity | Obtain registry read access, inspect both private packages and compare deployed image identities. |
| Hostinger health and persistent restart | SSH access, host/workload inventory, guarded bootstrap or maintenance upgrade, container/host restart and all three stores. |
| Cloudflare DNS and public TLS | Register/delegate the domain without an unapproved charge; validate API/preview host and HTTP/WebSocket authorization policy. |
| R2 backup and restore | Enable private bucket/scoped credentials; initialize restic, upload a consistent three-store checkpoint, retrieve, validate, restore into disposable storage and run the documented same-volume drill. |
| Real-model Quasar lifecycle | Deployed desktop HTTP create/review/approve/prepare/preview/edit/rollback/archive/restore, restart recovery, cancellation and uncertain-mutation non-replay. |
| Discord proposal authorization | Authorized approval/action followed by fresh permission-revocation denial in the isolated guild. |
| Twitch Helix/EventSub | Public HTTPS subscription/delivery handshake, signature/replay/retry handling and intended side effects. |
| Discord audio, camera and Go Live | Authorized participant consent, metadata-only codec observation, observed-codec implementation/composition and an exact-candidate all-true `LiveMediaQualificationReceipt`. |

Audio capture/send/receive/playback components are locally composed. The default
factory reports `.locallyComposed` when source and sink exist; a one-use consent
qualification lease can admit the explicit canary. This is not a live-call
qualification receipt. Video selection is still intentionally unmodeled on the
wire; the diagnostic probe cannot authorize transmission. Typed negotiation,
the selected codec's final production composition and live promotion remain
dependent on the consented protocol observation. No capture was started for
this integration pass.
