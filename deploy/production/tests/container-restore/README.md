# Disposable release-image restore gate

Run after the Abbey and Caddy release images have been built:

```bash
ABBEY_RELEASE_IMAGE=abbeybot-release-gate:local \
ABBEY_CADDY_RELEASE_IMAGE=abbeybot-caddy-release-gate:local \
bash deploy/production/tests/container-restore.sh
```

Requires Linux, Docker Engine/Compose v2, Bash, Python 3.11+, and `flock`.
The gate pulls pinned PostgreSQL 16 and restic 0.18.0 helper images. It does not
install tools, build Abbey, connect to a hosted database, publish host ports, or
use provider credentials. All service communication stays on an internal
Compose network; validation containers have no network. Resources use a random
per-run prefix, and cleanup removes only that gate's resources.

The production backup and restore scripts are copied unchanged into private
scratch. The Docker shim delegates actual SQL, image inspection, health checks,
tar creation/extraction, and container lifecycle operations to Docker. It maps
fixed production volume names to gate-specific volumes and unpublished digest
aliases to the exact local release images already tested by the parent gate.
An unexpected production volume or GHCR digest is refused.

The restic shim invokes **real restic** in a network-disabled container against
an **encrypted local repository** with synthetic credentials. It overrides the
synthetic R2-shaped configuration at this test boundary. This exercises repository
creation, backup, data checking, retrieval, and checksum verification. It does
not establish Cloudflare R2 access, off-host durability, or GHCR authentication.

The gate checks:

1. Production backup of a real PostgreSQL database and both release-image state
   volumes, with SQL/file probes and health through the release Caddy image.
2. Automatic recovery of all three stores after one injected failure **after
   real state extraction completes**, using unchanged production EXIT recovery.
3. Refusal of a corrupt-but-checksummed PostgreSQL dump during actual disposable
   `pg_restore`, before service interruption.
4. Retrieval through real restic followed by successful production restoration
   and SQL/file/HTTP verification.

Local helper validation:

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover \
  -s deploy/production/tests/container-restore -p 'test_*.py'
shellcheck -x deploy/production/tests/container-restore.sh
```

Shell/helper results are distinct from executing the real-container gate. The
implementation workstation had no Docker executable at authoring time; hosted
execution must supply the runtime result. This gate uses a private HTTP Caddy
fixture, so public TLS/DNS, external model, Discord, and production policy
configuration remain separate acceptance requirements.
