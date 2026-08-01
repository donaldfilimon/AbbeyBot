#!/usr/bin/env bash
# Deterministic, dependency-free static/security checks shared by local and CI gates.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "======== static: diff and merge-marker hygiene ========"
git diff --check
git diff --cached --check

if git grep -IlE '^(<<<<<<< |=======|>>>>>>> )' -- . \
  ':(exclude)Package.resolved' >/tmp/abbey-conflict-files.txt; then
  echo "STATIC_FAIL: unresolved merge marker(s) in tracked files:" >&2
  sed 's/^/  /' /tmp/abbey-conflict-files.txt >&2
  exit 1
fi

# SwiftPM compiles untracked Swift files inside target directories too. Finder/iCloud conflict
# copies such as `ModelContainerBootstrap 2.swift` therefore cause invalid redeclarations before
# they are staged. Inspect tracked plus untracked, non-ignored target files so the static gate
# catches the problem at its source.
duplicate_swift_sources=()
while IFS= read -r -d '' path; do
  if [[ "$path" =~ \ [0-9]+\.swift$ ]]; then
    duplicate_swift_sources+=("$path")
  fi
done < <(git ls-files -co --exclude-standard -z -- Sources Tests)
if [[ "${#duplicate_swift_sources[@]}" -gt 0 ]]; then
  echo "STATIC_FAIL: Finder/iCloud-style duplicate Swift source(s) detected:" >&2
  printf '  %s\n' "${duplicate_swift_sources[@]}" >&2
  exit 1
fi

echo "======== security: tracked filenames ========"
bad_names=()
while IFS= read -r -d '' path; do
  case "$path" in
    .env.example) ;;
    .env|.env.*|*.pem|*.key|*.p12|*.pfx|credentials.json|service-account*.json)
      bad_names+=("$path")
      ;;
  esac
done < <(git ls-files -z)
if [[ "${#bad_names[@]}" -gt 0 ]]; then
  echo "SECURITY_FAIL: sensitive filename(s) are tracked:" >&2
  printf '  %s\n' "${bad_names[@]}" >&2
  exit 1
fi

echo "======== security: high-confidence secret signatures ========"
# Report filenames only so a real credential is never echoed into CI logs.
secret_pattern='(-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----|AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9_-]{20,}|[A-Za-z0-9_-]{24}\.[A-Za-z0-9_-]{6}\.[A-Za-z0-9_-]{27,})'
if git grep -IlE "$secret_pattern" -- . \
  ':(exclude)Package.resolved' >/tmp/abbey-secret-files.txt; then
  echo "SECURITY_FAIL: possible committed credential signature(s) in:" >&2
  sed 's/^/  /' /tmp/abbey-secret-files.txt >&2
  exit 1
fi

echo "STATIC_SECURITY_GREEN"
