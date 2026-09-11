#!/usr/bin/env bash
# Start recovery polling on the first event after install as well as at startup.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$here/watch.sh" start
exec "$here/renumber.sh"
