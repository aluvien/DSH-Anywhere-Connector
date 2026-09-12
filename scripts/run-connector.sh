#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
connector_config=${DSH_ANYWHERE_CONFIG:-"${HOME}/Library/Application Support/DSH Anywhere/connector.json"}
node_command=${DSH_ANYWHERE_NODE_BIN:-node}

if [ "${DSH_ANYWHERE_SKIP_BUILD:-0}" != "1" ]; then
  pnpm --dir "$project_root" --filter @dsh-anywhere/connector build
fi
exec "$node_command" "$project_root/packages/connector/lib/cli.js" start --config "$connector_config" "$@"
