#!/usr/bin/env bash
set -euo pipefail
unset TOOLCHAINS
export ABBEY_PACKAGE_ROLE=server
# Abbey's local data (DQN journal/checkpoint, WDBX, rollback, cursors) goes to a disposable
# directory, never the operator's ~/.abbey. An inherited ABBEY_DATA_DIR is deliberately ignored.
ABBEY_DATA_DIR="$(mktemp -d "${TMPDIR:-/tmp}/abbey-knowledge-data.XXXXXX")"
export ABBEY_DATA_DIR
trap 'rm -rf "$ABBEY_DATA_DIR"' EXIT
/usr/bin/xcrun --toolchain default swift test --filter 'KnowledgeAndStructuredInferenceTests/bundledSnapshotIsSignedAndByteExact'
echo KNOWLEDGE_SNAPSHOT_GREEN
