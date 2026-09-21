#!/bin/sh
set -eu

# Installs the local bridge and outbound Connector as systemd user services.
# All credentials stay in connector.json/bridge.env; the unit files only hold
# paths to the private runtime installed for this user.

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
config_path=${DSH_ANYWHERE_CONFIG:-"${XDG_CONFIG_HOME:-${HOME}/.config}/dsh-anywhere/connector.json"}
node_bin=${DSH_ANYWHERE_NODE_BIN:-$(command -v node || true)}
dsh_bin=${DSH_ANYWHERE_DSH_BIN:-$(command -v dsh || true)}
unit_dir="${XDG_CONFIG_HOME:-${HOME}/.config}/systemd/user"
log_dir="$(dirname -- "$config_path")/logs"

usage() {
  echo "Usage: $0 [--config <path>] [--node <path>] [--dsh <path>] [--uninstall]" >&2
  exit 64
}

uninstall=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --config) [ "$#" -ge 2 ] || usage; config_path=$2; shift 2 ;;
    --node) [ "$#" -ge 2 ] || usage; node_bin=$2; shift 2 ;;
    --dsh) [ "$#" -ge 2 ] || usage; dsh_bin=$2; shift 2 ;;
    --uninstall) uninstall=1; shift ;;
    *) usage ;;
  esac
done

command -v systemctl >/dev/null 2>&1 || {
  echo "systemd is required for the Linux background services." >&2
  exit 1
}

if [ "$uninstall" -eq 1 ]; then
  systemctl --user disable --now dsh-anywhere-bridge.service dsh-anywhere-connector.service >/dev/null 2>&1 || true
  rm -f "$unit_dir/dsh-anywhere-bridge.service" "$unit_dir/dsh-anywhere-connector.service"
  systemctl --user daemon-reload
  echo "Removed DSH Anywhere systemd user services."
  exit 0
fi

[ -f "$config_path" ] || { echo "Missing connector config: $config_path" >&2; exit 1; }
[ -n "$node_bin" ] && [ -x "$node_bin" ] || { echo "Cannot find Node.js." >&2; exit 1; }
[ -n "$dsh_bin" ] && [ -x "$dsh_bin" ] || { echo "Cannot find dsh." >&2; exit 1; }
systemctl --user show-environment >/dev/null 2>&1 || {
  echo "The systemd user manager is unavailable for this login." >&2
  exit 1
}

mkdir -p "$unit_dir" "$log_dir"

systemd_value() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/%/%%/g'
}

project_escaped=$(systemd_value "$project_root")
config_escaped=$(systemd_value "$config_path")
node_escaped=$(systemd_value "$node_bin")
dsh_escaped=$(systemd_value "$dsh_bin")
bridge_log=$(systemd_value "$log_dir/bridge.log")
connector_log=$(systemd_value "$log_dir/connector.log")

cat >"$unit_dir/dsh-anywhere-bridge.service" <<EOF
[Unit]
Description=DSH Anywhere local bridge
After=network.target

[Service]
Type=simple
WorkingDirectory="$project_escaped"
Environment="DSH_ANYWHERE_CONFIG=$config_escaped"
Environment="DSH_ANYWHERE_SKIP_BUILD=1"
Environment="DSH_ANYWHERE_NODE_BIN=$node_escaped"
Environment="DSH_ANYWHERE_DSH_BIN=$dsh_escaped"
ExecStart=/bin/sh "$project_escaped/scripts/run-bridge.sh"
Restart=always
RestartSec=3
StandardOutput=append:$bridge_log
StandardError=append:$bridge_log

[Install]
WantedBy=default.target
EOF

cat >"$unit_dir/dsh-anywhere-connector.service" <<EOF
[Unit]
Description=DSH Anywhere Relay connector
After=network-online.target dsh-anywhere-bridge.service
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory="$project_escaped"
Environment="DSH_ANYWHERE_CONFIG=$config_escaped"
Environment="DSH_ANYWHERE_SKIP_BUILD=1"
Environment="DSH_ANYWHERE_NODE_BIN=$node_escaped"
ExecStart=/bin/sh "$project_escaped/scripts/run-connector.sh"
Restart=always
RestartSec=3
StandardOutput=append:$connector_log
StandardError=append:$connector_log

[Install]
WantedBy=default.target
EOF

chmod 600 "$unit_dir/dsh-anywhere-bridge.service" "$unit_dir/dsh-anywhere-connector.service"
systemctl --user daemon-reload
systemctl --user enable dsh-anywhere-bridge.service dsh-anywhere-connector.service
systemctl --user restart dsh-anywhere-bridge.service dsh-anywhere-connector.service

# Linger keeps the user manager alive after logout on hosts whose policy lets a
# user enable it for their own account. Installation remains usable during the
# current login when the host reserves this operation for an administrator.
if command -v loginctl >/dev/null 2>&1; then
  loginctl enable-linger "$(id -un)" >/dev/null 2>&1 || true
fi

echo "Installed and started DSH Anywhere systemd user services."
