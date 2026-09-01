#!/usr/bin/env bash
# Runs every suite and reports a combined result. This is what CI runs.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

command -v jq >/dev/null || { echo "missing dependency: jq" >&2; exit 2; }

rc=0
for t in "$DIR"/test_*.sh; do
  bash "$t" || rc=1
done

echo
if [ "$rc" -eq 0 ]; then echo "all suites passed"; else echo "SOME SUITES FAILED"; fi
exit "$rc"
