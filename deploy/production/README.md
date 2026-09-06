# AbbeyBot production deployment

This bundle runs the full server graph, Postgres, private Quasar previews, and
Caddy on any x86-64 Linux host with Docker Engine and Docker Compose v2. The
host pulls immutable GHCR images built by GitHub Actions. Runtime scripts require
Bash, Python 3.11+, util-linux `flock`, and restic. It does not need a Swift
toolchain, host Bun installation, Node.js, or `xcaddy`.

Only Caddy publishes host ports 80 and 443. Postgres, the Abbey API on 8080,
and the dynamically selected preview ports stay inside Compose networks.
Abbey uses an init process to reap preview descendants. Its read-only root
filesystem mounts separate persistent volumes for Quasar and
`/var/lib/abbey/.abbey` (DQN, WDBX and journal state).
Caddy asks Abbey's internal authorization endpoint for a server-derived
`abbey:<port>` upstream before every preview request. Incoming clients cannot
select that upstream. The ticket redemption path is
`/_quasar/preview-session?ticket=...`; Caddy does not enable access logging on
preview hosts, so ticket query strings are not written to its container log.

## Release images

`.github/workflows/release-images.yml` runs a read-only release-image gate on
pull requests to `main`. It boots the full server with a disposable SQLite
database, checks every packaged resource bundle, installs and renders the
bundled Quasar scaffold, and exercises authenticated create, approval, preparation,
preview and stop through Abbey with a deterministic provider fixture. It verifies
complete preview process-group absence after API stop and repeats preview after
server restart. The gate also runs the adapted production Caddy routes on a local
HTTP listener against fixture authorization and HTTP/WebSocket upstreams, checking
ticket-query preservation, replay denial, host binding, upstream selection and
credential/cookie filtering. This fixture gate does not establish public TLS,
real-provider generation or live Discord acceptance.
For commits merged to `main`, the same gate runs before the exact local Abbey
and Caddy images are tagged and pushed. Only that publish job receives
`packages: write`; it records the immutable GHCR digest references in the
workflow summary. Confirm that both GHCR packages remain private. The server's
registry credential needs only read access to those packages.

The Abbey image uses Bun 1.3.14 and the same Swift 6.4 Bookworm toolchain as
CI. Its release layer includes Bun, the Swift Linux runtime, and all three
server resource bundles: AbbeyCore contracts/knowledge, the Quasar Next.js
template, and AbbeyServer views/static assets. The Caddy image pins Caddy
2.11.4 and `caddy-dns/cloudflare` v0.2.4.

## Host prerequisites

Install a supported Docker Engine and Compose v2, configure the firewall for
SSH plus TCP 80/443 and UDP 443, and configure independent off-host backups.
Log in to `ghcr.io` with a read-only package credential before the first pull.
Do not place provider tokens in shell history or source control.

Copy `.env.example` to `.env`, set mode 0600, and replace every required
value. Generate a new URL-safe Postgres password for this deployment; a
64-character hex value from `openssl rand -hex 32` avoids URL-encoding issues
in `DATABASE_URL`. Generate separate random values for the Abbey operator,
Quasar operator, and internal Caddy service credentials. The internal service
credential is never accepted as an operator token.

The Cloudflare token is passed only to Caddy. Scope it to Zone Read and DNS
Edit for the single deployed zone. Before starting the stack, verify the zone
delegation and create only the API and wildcard preview records pointing to
the host. The expected names are `api.xfoss.dev` and
`*.preview.xfoss.dev`, unless the `.env` domains are changed together with
DNS.

Validate interpolation without printing the rendered configuration into a
shared log:

```bash
cd deploy/production
docker compose --env-file .env --file compose.yml config --quiet
scripts/deploy.sh --bootstrap \
  ghcr.io/donaldfilimon/abbeybot@sha256:<64-hex-digest> \
  ghcr.io/donaldfilimon/abbeybot-caddy@sha256:<64-hex-digest>
```

The deployment defaults to `https://api.openai.com/v1/chat/completions` and
`gpt-5.4-mini`, with no bearer credential in source. Set the provider token
privately before model acceptance. These defaults do not change the shared
inference router or prove model access.

`ABBEY_DRY_RUN=1` and `ABBEY_QUIET=1` are the initial values. The full
server lifecycle starts its Discord bridge automatically: dry-run uses its
in-memory path, while a live gateway opens only when dry-run is disabled and
`DISCORD_BOT_TOKEN` is nonempty. Enabling Discord Quasar proposals therefore
requires setting the bot token, `DISCORD_OPERATOR_USER_IDS`, the guild
allowlist and budget, and changing both policy switches only after review.
Local container health is not evidence of a live Discord or model-backed
interaction.

## Rollout and recovery

Run scripts from this directory or by absolute path. Each operation holds an
exclusive lock; a concurrent deploy, restore or backup is rejected. Configure
off-host backups before bootstrap or upgrades. `--bootstrap` is only for a
new host with no Abbey containers or Postgres/Quasar/Abbey-state volumes. An
ordinary upgrade requires an existing installation and valid previous digests.
Before downtime or checkpoint creation, backup/upgrade/restore compare the actual
running Abbey and Caddy image IDs with the locally resolved immutable `.env`
digests. Missing/stopped/ambiguous containers or edited configuration that differs
from the running images cause refusal. Reconcile `.env` to the actual installation
before retrying; changing `.env` alone never relabels a checkpoint.
Both paths pull the requested immutable images before interrupting service.

```bash
scripts/backup.sh
scripts/deploy.sh \
  ghcr.io/donaldfilimon/abbeybot@sha256:<64-hex-digest> \
  ghcr.io/donaldfilimon/abbeybot-caddy@sha256:<64-hex-digest>
scripts/restore.sh /absolute/path/to/verified-backup
```

`backup.sh` stops Caddy and Abbey, takes a consistent Postgres dump and archives
both application volumes, records checksums/image digests, uploads the checkpoint
through restic, and restarts the stack. Reproducible `node_modules` and `.next`
directories are excluded; dependency preparation is required after restoration.
Private backup directories use unique names and existing directories are never
overwritten. A failed upload retains the local checkpoint, restarts service and
returns failure. No script prunes local backups, image history or remote snapshots.

`restore.sh` freezes its input into a private staging directory and verifies the
fixed checksum manifest, required files and archive safety. Links, special files,
absolute paths, traversal and duplicate archive paths are rejected. It pulls the
recorded images and restores the dump to disposable PostgreSQL 16 storage and both
archives to a disposable Docker volume before stopping the live service. Validation
containers have no network access; the database is memory/CPU/process bounded.
It then holds ingress stopped while creating and uploading a pre-restore checkpoint.
Only after that succeeds does it replace all three stores and image references.
A data restore or application-health failure automatically restores the checkpoint
and previous images. Upgrades use the same data rollback if the new image fails
health, including when startup migrations have changed data.

If rollback itself fails, the application remains stopped and the script reports
the retained checkpoint for manual recovery. Power loss or SIGKILL can prevent shell
cleanup; recover from the retained checkpoint before reopening ingress. Startup
health is a local acceptance gate, not proof of external model, Discord or HTTPS
behavior. `.env` and backup credentials are intentionally absent from data archives;
keep their own encrypted recovery copies separately.

Backups from before Abbey-state persistence lack `state.tar.gz`. They remain on
disk, but automated restore rejects them before interruption rather than mixing an
old database with current model state. A legacy recovery needs a separately reviewed
complete checkpoint. The current format is `postgres.dump`, `quasar.tar.gz`,
`state.tar.gz`, `manifest.env`, and `SHA256SUMS`.

## Encrypted off-host backups

Enable R2 and create a private bucket. Create an **Object Read & Write** access key
scoped to that one bucket, separate from Caddy's DNS credential. Copy
`backup.env.example` to `.backup.env`, set mode 0600, and fill literal unquoted
`KEY=value` entries. Create a separate random restic password file at an absolute
path with mode 0600; retain a protected recovery copy outside the VPS. Credentials
are passed only to the restic subprocess and never added to Compose containers.
Bucket-scoped credentials and the S3 endpoint format follow the official
[Cloudflare R2 authentication documentation](https://developers.cloudflare.com/r2/api/tokens/)
and [restic S3-compatible repository documentation](https://restic.readthedocs.io/en/stable/030_preparing_a_new_repo.html#s3-compatible-storage).

```bash
# Explicit, one-time creation; existing repositories are never replaced.
scripts/backup-store.sh init
scripts/backup-store.sh check
scripts/backup-store.sh snapshots
# Destination must not already exist. Verify a chosen snapshot, then find its
# checkpoint directory containing SHA256SUMS and pass it to restore.sh.
scripts/backup-store.sh fetch <snapshot-id> /absolute/path/to/new-recovery-directory
```

Deploy/backup/restore preflight refuses missing private configuration, password,
credentials, a non-R2/non-HTTPS repository, or an inaccessible repository before
interruption. The upload itself must succeed before destructive changes. No retention
or prune policy is installed. Run `backup.sh` from the operator's existing scheduler
at the desired interval; scheduling and off-host restore drills need separate live
verification. Losing the restic password makes the encrypted snapshots unrecoverable.

## Verification

Run `bash deploy/production/tests/run.sh` from the repository root. These shell
entrypoint tests use fake Docker/restic executables, real backup files and archives,
and assert interruption order, refusal before mutation, retained checkpoints,
bootstrap behavior, restore of all three stores and failure recovery. Run
`shellcheck -x deploy/production/scripts/*.sh deploy/production/tests/run.sh` as well.
These tests do not establish actual PostgreSQL, image, encryption or R2 behavior;
retain the real Linux release-image and restore-drill acceptance gates.

After each rollout, record these evidence layers separately:

1. GitHub image workflow result and its exact digests.
2. Local Compose health and persistent-volume restart behavior.
3. Public HTTPS for the API and a private preview host.
4. A real external-model create, review, approve, prepare, preview, edit,
   rollback, archive, and restore lifecycle.
5. Operator-submitted Discord proposal approval and a current-policy denial
   after authorization is revoked.
6. Backup restore evidence on the same persistent volumes.

## Hostinger status on 2026-09-06

The selected Hostinger KVM 8 VPS was visible with Ubuntu 26.04, x86-64,
8 vCPUs, 32 GiB RAM, and 400 GiB storage. That inventory is provider-console
evidence only. Root SSH public-key authentication was still denied, Hostinger's
Docker Manager did not support the selected OS, and the provider showed no
backup points. Docker/Compose installation, working SSH administration, GHCR
read access, firewall/DNS changes, off-host backup configuration, and a real
container start remain prerequisites. Recheck this provider state before a
rollout because it can change independently of the repository.

On 2026-09-06 the parent integration session received R2 API error 10042,
"Please enable R2". Off-host backup acceptance therefore remains blocked on
account enablement, bucket/key creation and a successful remote restore drill.
