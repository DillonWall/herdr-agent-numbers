#!/usr/bin/env bash
# A running server can outlive its executable after a tool-manager update.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export TEST_STATE_DIR="$tmp" HERDR_SOCKET_PATH="$tmp/herdr.sock"
export AGENT_NUMBERS_SORT=priority
cp "$DIR/fake_herdr.sh" "$tmp/herdr"
chmod +x "$tmp/herdr"
export PATH="$tmp:$PATH"

for binary in "$tmp/removed/herdr" "$tmp/removed/herdr (deleted)"; do
  export HERDR_BIN_PATH="$binary"
  jq '.result.snapshot.panes = (.result.snapshot.agents | map({pane_id,tokens:{}}))' \
    "$DIR/fixtures/idle-only.json" > "$tmp/snapshot.json"
  bash "$DIR/../renumber.sh" --once
  jq -e '[.result.snapshot.panes[] | .tokens.num] == ["1","3","2"]' "$tmp/snapshot.json" >/dev/null
  bash "$DIR/../verify.sh" > "$tmp/verify.log"
  echo 'PASS: renumber and verify recover from a removed server binary'
done

# An executable override must still take precedence over PATH, even if it fails.
printf '#!/usr/bin/env bash\nexit 42\n' > "$tmp/override"
chmod +x "$tmp/override"
if HERDR_BIN_PATH="$tmp/override" bash "$DIR/../verify.sh" >/dev/null 2>&1; then
  echo 'an executable override was ignored' >&2
  exit 1
fi
echo 'PASS: executable overrides retain precedence'
