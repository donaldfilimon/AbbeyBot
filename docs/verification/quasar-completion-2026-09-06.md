# Quasar completion evidence — 2026-09-06

This is an implementation/rollout ledger, not a release certification. Pending rows remain pending until backed by an observed result.

**September 8 update:** repository integration and local verification advanced
after this entry. The [current integration ledger](product-integration-2026-09-08.md)
supersedes the pending Git/PR/local-gate claims below. This dated snapshot remains
as historical evidence; live rollout and provider acceptance are still open.

## Scope and integration

- Approved plan: [Quasar completion](../plans/2026-09-06-quasar-completion.md).
- User subsequently requested Hostinger as the deployment access surface and requested all completed work merged into main.
- Implementation branch: `cursor/quasar-completion-20260906`, based on committed correctness work `31d1f56` in an isolated adjacent checkout because the canonical checkout remains under active changes by another session.
- No Quasar commit, PR, image digest, production rollout or live model acceptance recorded yet.

## Local evidence

| Gate | Observed result |
| --- | --- |
| `Scripts/run-web-smoke.sh` | Passed (install, lint, tests, build, packed resources) |
| `Scripts/check-static-security.sh` | Passed during implementation |
| Swift focused integration tests | In progress; initial runs rejected missing interfaces while implementation was underway |
| `Scripts/verify-all.sh` | Pending |
| Actual Linux release image boot and lifecycle | Pending |
| Hosted CI and reviewed main integration | Pending |

## Hosting and domain evidence

- Hostinger account lists existing running VPS `srv1955556.hstgr.cloud`, VM ID `1955556`, KVM 8, Ubuntu 26.04 LTS, 8 CPUs, 32 GiB RAM, 400 GiB disk, IPv4 `2.25.160.8`.
- No new server was purchased. The original DigitalOcean price estimate is not an estimate for this existing Hostinger subscription.
- Hostinger Docker project inventory reports that the current OS does not support Docker Manager. This is not proof Docker itself is absent.
- Hostinger backup inventory returned no backup points. Daily backup coverage is unverified.
- Registered the existing Mac public SSH key under `Donald MacBook deployment` (public-key ID `573580`), then requested attachment to VM `1955556`. Registration succeeded; attachment returned an empty action record. Subsequent SSH public-key authentication remained denied, and attached-key inventory returned route-not-found. Deployment SSH access remains blocked pending hPanel/key configuration or the existing deployment username.
- Earlier Cloudflare inspection found `xfoss.dev` pending, no zone DNS records, assigned nameservers `elmo.ns.cloudflare.com` and `sloan.ns.cloudflare.com`; local nameserver lookup returned SERVFAIL.
- Hostinger domain lookup reports `xfoss.dev` is not registered at Hostinger. Domain registration/delegation is not established by these observations. No domain purchase, nameserver update or DNS record mutation has been performed.

## Live acceptance (all pending)

- Exact immutable image digest deployed through maintenance backup and health checks.
- HTTPS API and wildcard private preview origins, authorized HTTP and WebSocket traffic.
- Desktop over HTTPS, real configured model: create → review → approve → prepare → preview → edit → rollback → archive → restore.
- Operator-submitted Discord proposal approval and current permission-revocation denial in the designated test guild.
- Deployed service restart with persisted recovery/history and verified restore from retained backup.

Provider model/credentials, Discord test guild/application, secure SSH access, working domain delegation and daily backup configuration remain rollout prerequisites. Secrets must be configured through secure account/server settings; no credentials belong in this ledger.
