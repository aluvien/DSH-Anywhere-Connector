#!/usr/bin/env bash
# Start (or report) the local relay + mock machine bed used by DSHLiveRelayTest.
# Idempotent: prints SKIP if the bed already answers on :8787.
set -e
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
if curl -s -m 1 http://127.0.0.1:8787/health >/dev/null 2>&1; then
  echo "bed already running: $(curl -s http://127.0.0.1:8787/health)"
  exit 0
fi
mkdir -p "$ROOT/.relay-local"
cd "$ROOT/.relay-local"
[ -f token.txt ] || printf 'DSH_RELAY_BOOTSTRAP_TOKEN=%s\n' "$(openssl rand -hex 24)" > /dev/null && [ -s token.txt ] || openssl rand -hex 24 > token.txt
export DSH_RELAY_BOOTSTRAP_TOKEN=$(cat token.txt) PORT=8787
export DSH_RELAY_REGISTRY_PATH="$PWD/registry.json"
nohup node "$ROOT/packages/relay-server/dist/index.js" > relay.log 2>&1 &
sleep 1
REG=$(curl -s -X POST http://127.0.0.1:8787/v1/machines/register \
  -H "Content-Type: application/json" -H "Authorization: Bearer $DSH_RELAY_BOOTSTRAP_TOKEN" \
  -d '{"machineName":"testbed-mac"}')
echo "$REG" > reg.json
python3 - "$REG" <<'PY'
import json,sys
d=json.loads(sys.argv[1])
open("machine.txt","w").write(d["machineId"])
open("secret.txt","w").write(d["pairingSecret"])
open("machine-token.txt","w").write(d["machineToken"])
PY
nohup node "$ROOT/android/tools/mock-machine.mjs" --relay ws://127.0.0.1:8787/v1/connect \
  --machine-id "$(cat machine.txt)" --token "$(cat machine-token.txt)" > mock.log 2>&1 &
sleep 1
echo "bed up: relay :8787 + mock machine $(cat machine.txt)"
