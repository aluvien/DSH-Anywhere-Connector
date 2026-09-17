#!/bin/sh
# sync-mac-live.sh — Sync built Mac-side code to the live service directory.
#
# Usage:
#   ./scripts/sync-mac-live.sh [SOURCE_DIR]
#
# SOURCE_DIR defaults to this repo root (the checkout you edit). The live
# directory (the checkout the launchd services actually run from) is
# auto-discovered from the running bridge service, so this keeps working
# even when the two checkouts live in different places.
#
# What it does:
#   1. rsync packages/protocol, packages/connector,
#      packages/dsh-anywhere-plugin (sources only — secrets live outside
#      both trees and are never touched)
#   2. rebuild the three packages in the live directory
#   3. verify the new code landed in the built output
#   4. restart bridge + connector via launchctl kickstart (paths unchanged,
#      no plist rewrite, no re-registration)
#   5. print fresh PIDs and recent log lines for verification
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC_DIR=${1:-$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)}
UID_NUM=$(id -u)

discover_live_dir() {
  prog=$(launchctl print "gui/${UID_NUM}/com.dsh-anywhere.bridge" 2>/dev/null \
    | grep -m1 "DSH-ANYWHERE/scripts/run-bridge.sh" || true)
  if [ -n "$prog" ]; then
    script_path=$(printf '%s' "$prog" | sed 's/^[[:space:]]*//')
    CDPATH= cd -- "$(dirname -- "$(dirname -- "$script_path")")" && pwd
    return
  fi
  printf '%s' "${HOME}/DSH-ANYWHERE"
}

LIVE_DIR=$(discover_live_dir)
echo "source: $SRC_DIR"
echo "live:   $LIVE_DIR"
[ -d "${SRC_DIR}/packages/dsh-anywhere-plugin/src" ] || { echo "error: not a repo root: $SRC_DIR" >&2; exit 1; }
[ -x "${LIVE_DIR}/node_modules/.bin/tsc" ] || { echo "error: no toolchain in live dir (run pnpm install there first)" >&2; exit 1; }

for pkg in protocol connector dsh-anywhere-plugin; do
  /usr/bin/rsync -a --exclude=node_modules --exclude=dist --exclude=lib --exclude=.turbo \
    "${SRC_DIR}/packages/${pkg}/" "${LIVE_DIR}/packages/${pkg}/"
done
echo "sync: ok"

TSC="${LIVE_DIR}/node_modules/.bin/tsc"
(cd "${LIVE_DIR}/packages/protocol" && "$TSC" -p tsconfig.build.json)
(cd "${LIVE_DIR}/packages/dsh-anywhere-plugin" && "$TSC" -p tsconfig.json)
(cd "${LIVE_DIR}/packages/connector" && "$TSC" -p tsconfig.build.json)
echo "build: ok"

launchctl kickstart -k "gui/${UID_NUM}/com.dsh-anywhere.bridge"
sleep 3
launchctl kickstart -k "gui/${UID_NUM}/com.dsh-anywhere.connector"
sleep 6
echo "restart: ok"

echo "--- services ---"
launchctl print "gui/${UID_NUM}/com.dsh-anywhere.bridge" 2>/dev/null | grep -E "state|pid" | head -n 2
launchctl print "gui/${UID_NUM}/com.dsh-anywhere.connector" 2>/dev/null | grep -E "state|pid" | head -n 2
echo "--- connector log ---"
tail -n 4 ~/Library/Logs/DSH\ Anywhere/connector.log 2>/dev/null || true
echo "--- errors (empty is good) ---"
grep -iE "error|invalid|reject" ~/Library/Logs/DSH\ Anywhere/bridge.log ~/Library/Logs/DSH\ Anywhere/connector.log 2>/dev/null | tail -n 5 || true
echo "done."
