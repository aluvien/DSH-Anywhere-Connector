#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
bridge_port=${DSH_ANYWHERE_PORT:-3080}
dsh_command=${DSH_ANYWHERE_DSH_BIN:-dsh}
node_command=${DSH_ANYWHERE_NODE_BIN:-node}
connector_config=${DSH_ANYWHERE_CONFIG:-"${HOME}/Library/Application Support/DSH Anywhere/connector.json"}
connector_config_dir=$(dirname -- "$connector_config")
bridge_env=${DSH_ANYWHERE_BRIDGE_ENV:-"${connector_config_dir}/bridge.env"}

# Keep child tools discoverable when this script is started by launchd, whose
# default PATH does not include a user-local Node installation.
if [ -n "${DSH_ANYWHERE_NODE_BIN:-}" ]; then
  PATH=$(dirname -- "$DSH_ANYWHERE_NODE_BIN"):$PATH
fi
if [ -n "${DSH_ANYWHERE_DSH_BIN:-}" ]; then
  PATH=$(dirname -- "$DSH_ANYWHERE_DSH_BIN"):$PATH
fi
export PATH

# `dsh-anywhere setup` writes the plugin token next to connector.json. Sourcing
# this file keeps the token out of shell history and makes the bridge safe to
# launch from Terminal, launchd, or a future installer.
if [ -f "$bridge_env" ]; then
  # shellcheck disable=SC1090
  . "$bridge_env"
fi
# bridge.env is intentionally a simple KEY=value file. Export the sourced
# token before starting Node so the Cordis plugin can authenticate Connector's
# /events WebSocket (without putting the token in the launchd plist).
if [ -n "${DSH_ANYWHERE_CONNECTOR_TOKEN:-}" ]; then
  export DSH_ANYWHERE_CONNECTOR_TOKEN
fi

if [ "${DSH_ANYWHERE_SKIP_BUILD:-0}" != "1" ]; then
  pnpm --dir "$project_root" build
fi
# Invoke the Node entrypoint explicitly. launchd uses a minimal PATH, so a
# dsh script with #!/usr/bin/env node would otherwise exit with code 127.
exec "$node_command" "$dsh_command" web \
  --patch "$project_root/packages/dsh-anywhere-plugin/cordis.patch.yml" \
  --port "$bridge_port" \
  --no-open "$@"
