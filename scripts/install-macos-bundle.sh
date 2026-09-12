#!/bin/sh
set -eu

# Install the local DSH Anywhere services from a copied bundle. Keep this
# bundle outside ~/Documents so macOS launchd can execute its scripts.
project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
config_path=${DSH_ANYWHERE_CONFIG:-"${HOME}/Library/Application Support/DSH Anywhere/connector.json"}
relay_url=${DSH_ANYWHERE_RELAY_URL:-}
bootstrap_token=${DSH_ANYWHERE_BOOTSTRAP_TOKEN:-}
machine_name=${DSH_ANYWHERE_MACHINE_NAME:-}
bridge_base_url=${DSH_ANYWHERE_BRIDGE_BASE_URL:-}

cd "$project_root"

command -v node >/dev/null 2>&1 || { echo "Missing Node.js 22+." >&2; exit 1; }
command -v pnpm >/dev/null 2>&1 || { echo "Missing pnpm." >&2; exit 1; }
command -v dsh >/dev/null 2>&1 || { echo "Missing the DeepSeek Harness 'dsh' command." >&2; exit 1; }

node -e 'const major=Number(process.versions.node.split(".")[0]); if (major < 22) { console.error(`Node.js 22+ required; found ${process.versions.node}`); process.exit(1); }'

pnpm install --config.confirmModulesPurge=false
pnpm build

# Reuse an existing registration. A new registration is only needed when the
# connector config is absent, and the bootstrap token is never stored in the
# bundle or in a launchd plist.
if [ ! -f "$config_path" ]; then
  [ -n "$relay_url" ] || { echo "Set DSH_ANYWHERE_RELAY_URL before first setup." >&2; exit 1; }
  [ -n "$bootstrap_token" ] || { echo "Set DSH_ANYWHERE_BOOTSTRAP_TOKEN before first setup." >&2; exit 1; }
  if [ -z "$machine_name" ]; then
    machine_name=$(scutil --get ComputerName 2>/dev/null || hostname)
  fi
  if [ -n "$bridge_base_url" ]; then
    node packages/connector/lib/cli.js setup \
      --relay "$relay_url" \
      --bootstrap-token "$bootstrap_token" \
      --machine-name "$machine_name" \
      --bridge-base-url "$bridge_base_url" \
      --config "$config_path"
  else
    node packages/connector/lib/cli.js setup \
      --relay "$relay_url" \
      --bootstrap-token "$bootstrap_token" \
      --machine-name "$machine_name" \
      --config "$config_path"
  fi
fi

./scripts/install-macos-services.sh --config "$config_path"
echo "DSH Anywhere local services installed from: $project_root"
