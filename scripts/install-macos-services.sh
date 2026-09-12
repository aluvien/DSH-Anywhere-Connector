#!/bin/sh
set -eu

# Install the two user-level processes needed by the private macOS MVP:
# the local DSH bridge and the outbound Connector. No credential is written
# into either plist; run-bridge.sh reads bridge.env at launch time.

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
config_path=${DSH_ANYWHERE_CONFIG:-"${HOME}/Library/Application Support/DSH Anywhere/connector.json"}
launch_agents_dir=${HOME}/Library/LaunchAgents
bridge_label=com.dsh-anywhere.bridge
connector_label=com.dsh-anywhere.connector
bridge_plist=${launch_agents_dir}/${bridge_label}.plist
connector_plist=${launch_agents_dir}/${connector_label}.plist
log_dir=${HOME}/Library/Logs/DSH\ Anywhere

usage() {
  echo "Usage: $0 [--config <path>] [--uninstall]" >&2
  exit 64
}

uninstall=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --config)
      [ "$#" -ge 2 ] || usage
      config_path=$2
      shift 2
      ;;
    --uninstall)
      uninstall=1
      shift
      ;;
    *)
      usage
      ;;
  esac
done

uid=$(id -u)
domain="gui/${uid}"
dsh_bin=$(command -v dsh || true)
node_bin=$(command -v node || true)

unload() {
  launchctl bootout "$domain" "$1" >/dev/null 2>&1 || true
}

if [ "$uninstall" -eq 1 ]; then
  unload "$bridge_plist"
  unload "$connector_plist"
  rm -f "$bridge_plist" "$connector_plist"
  echo "Removed DSH Anywhere launch agents."
  exit 0
fi

[ -f "$config_path" ] || {
  echo "Missing connector config: $config_path (run dsh-anywhere setup first)" >&2
  exit 1
}
[ -n "$dsh_bin" ] || { echo "Cannot find dsh in PATH." >&2; exit 1; }
[ -n "$node_bin" ] || { echo "Cannot find node in PATH." >&2; exit 1; }

mkdir -p "$launch_agents_dir" "$log_dir"
pnpm --dir "$project_root" build

write_plist() {
  label=$1
  script=$2
  output=$3
  stdout_path=$4
  stderr_path=$5
  /usr/bin/plutil -convert xml1 -o "$output" - <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${label}</string>
  <key>ProgramArguments</key>
  <array><string>/bin/sh</string><string>${script}</string></array>
  <key>WorkingDirectory</key><string>${project_root}</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>DSH_ANYWHERE_CONFIG</key><string>${config_path}</string>
    <key>DSH_ANYWHERE_SKIP_BUILD</key><string>1</string>
    <key>DSH_ANYWHERE_DSH_BIN</key><string>${dsh_bin}</string>
    <key>DSH_ANYWHERE_NODE_BIN</key><string>${node_bin}</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>${stdout_path}</string>
  <key>StandardErrorPath</key><string>${stderr_path}</string>
</dict>
</plist>
EOF
  /usr/bin/plutil -lint "$output" >/dev/null
}

write_plist "$bridge_label" "$project_root/scripts/run-bridge.sh" "$bridge_plist" \
  "$log_dir/bridge.log" "$log_dir/bridge.err.log"
write_plist "$connector_label" "$project_root/scripts/run-connector.sh" "$connector_plist" \
  "$log_dir/connector.log" "$log_dir/connector.err.log"

unload "$bridge_plist"
unload "$connector_plist"
launchctl bootstrap "$domain" "$bridge_plist"
launchctl bootstrap "$domain" "$connector_plist"
launchctl kickstart -k "${domain}/${bridge_label}"
launchctl kickstart -k "${domain}/${connector_label}"
echo "Installed and started DSH Anywhere bridge + Connector launch agents."
