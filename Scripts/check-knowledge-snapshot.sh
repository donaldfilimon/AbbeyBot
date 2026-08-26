#!/usr/bin/env bash
set -euo pipefail
unset TOOLCHAINS
export ABBEY_PACKAGE_ROLE=server
/usr/bin/xcrun --toolchain default swift test --filter 'KnowledgeAndStructuredInferenceTests/bundledSnapshotIsSignedAndByteExact'
echo KNOWLEDGE_SNAPSHOT_GREEN
