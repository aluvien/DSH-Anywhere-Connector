#!/bin/sh
set -eu

# This file is served by Relay after its placeholders have been replaced with
# a short-lived, single-use enrollment token and the operator's public URLs.
# Users only need: curl -fsSL https://relay.example/install | sh

relay_url='__DSH_RELAY_URL__'
enrollment_token='__DSH_ENROLLMENT_TOKEN__'
source_archive_url='__DSH_SOURCE_ARCHIVE_URL__'

if [ "$(uname -s)" != "Darwin" ]; then
  echo "DSH Anywhere currently supports macOS only." >&2
  exit 1
fi

support_dir="${HOME}/Library/Application Support/DSH Anywhere"
config_path="${support_dir}/connector.json"
runtime_dir="${support_dir}/runtime"
bundle_dir="${support_dir}/app"
temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/dsh-anywhere-install.XXXXXX")
next_bundle="${support_dir}/app.next.$$"
previous_bundle="${support_dir}/app.previous"

cleanup() {
  rm -rf -- "$temporary_dir" "$next_bundle"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$support_dir" "$runtime_dir"
chmod 700 "$support_dir" "$runtime_dir"

node_command=$(command -v node || true)
node_usable=0
if [ -n "$node_command" ]; then
  if "$node_command" -e 'process.exit(Number(process.versions.node.split(".")[0]) >= 22 ? 0 : 1)' 2>/dev/null; then
    node_usable=1
  fi
fi

if [ "$node_usable" -ne 1 ]; then
  node_version=v22.19.0
  case "$(uname -m)" in
    arm64) node_arch=arm64 ;;
    x86_64) node_arch=x64 ;;
    *) echo "Unsupported Mac architecture: $(uname -m)" >&2; exit 1 ;;
  esac
  node_home="${runtime_dir}/node-${node_version}-darwin-${node_arch}"
  if [ ! -x "${node_home}/bin/node" ]; then
    node_archive="node-${node_version}-darwin-${node_arch}.tar.gz"
    node_base="https://nodejs.org/dist/${node_version}"
    echo "Installing the private Node.js runtime…"
    /usr/bin/curl -fsSL "${node_base}/${node_archive}" -o "${temporary_dir}/${node_archive}"
    /usr/bin/curl -fsSL "${node_base}/SHASUMS256.txt" -o "${temporary_dir}/SHASUMS256.txt"
    expected_hash=$(awk -v name="$node_archive" '$2 == name { print $1 }' "${temporary_dir}/SHASUMS256.txt")
    actual_hash=$(/usr/bin/shasum -a 256 "${temporary_dir}/${node_archive}" | awk '{ print $1 }')
    [ -n "$expected_hash" ] && [ "$expected_hash" = "$actual_hash" ] || {
      echo "Node.js download verification failed." >&2
      exit 1
    }
    extracted_node="${temporary_dir}/node"
    mkdir -p "$extracted_node"
    /usr/bin/tar -xzf "${temporary_dir}/${node_archive}" -C "$extracted_node" --strip-components 1
    mv "$extracted_node" "$node_home"
  fi
  node_command="${node_home}/bin/node"
fi

node_bin_dir=$(dirname -- "$node_command")
npm_command="${node_bin_dir}/npm"
[ -x "$npm_command" ] || npm_command=$(command -v npm || true)
[ -n "$npm_command" ] || { echo "npm is unavailable." >&2; exit 1; }

tools_prefix="${runtime_dir}/tools"
echo "Preparing DSH Anywhere tools…"
"$npm_command" install --global --prefix "$tools_prefix" --silent \
  pnpm@11.9.0 @deepseek-ai/dsh@0.1.5-rc.2
PATH="${tools_prefix}/bin:${node_bin_dir}:${PATH}"
export PATH

echo "Downloading DSH Anywhere…"
/usr/bin/curl -fsSL "$source_archive_url" -o "${temporary_dir}/source.tar.gz"
mkdir -p "$next_bundle"
/usr/bin/tar -xzf "${temporary_dir}/source.tar.gz" -C "$next_bundle" --strip-components 1

pnpm --dir "$next_bundle" install --frozen-lockfile --config.confirmModulesPurge=false
pnpm --dir "$next_bundle" build

if [ -d "$previous_bundle" ]; then
  rm -rf -- "$previous_bundle"
fi
if [ -d "$bundle_dir" ]; then
  mv "$bundle_dir" "$previous_bundle"
fi
mv "$next_bundle" "$bundle_dir"

machine_name=$(scutil --get ComputerName 2>/dev/null || hostname)
if [ ! -f "$config_path" ]; then
  echo "Registering this Mac…"
  if ! DSH_ANYWHERE_ENROLLMENT_TOKEN="$enrollment_token" \
    "$node_command" "$bundle_dir/packages/connector/lib/cli.js" enroll \
      --relay "$relay_url" \
      --machine-name "$machine_name" \
      --config "$config_path"; then
    if [ -d "$previous_bundle" ]; then
      rm -rf -- "$bundle_dir"
      mv "$previous_bundle" "$bundle_dir"
    fi
    exit 1
  fi
fi

if ! PATH="${tools_prefix}/bin:${node_bin_dir}:${PATH}" \
    "$bundle_dir/scripts/install-macos-services.sh" --config "$config_path"; then
  if [ -d "$previous_bundle" ]; then
    rm -rf -- "$bundle_dir"
    mv "$previous_bundle" "$bundle_dir"
    PATH="${tools_prefix}/bin:${node_bin_dir}:${PATH}" \
      "$bundle_dir/scripts/install-macos-services.sh" --config "$config_path" || true
  fi
  exit 1
fi
rm -rf -- "$previous_bundle"

echo
echo "Scan this one-time QR code with DSH Anywhere on iPhone:"
"$node_command" "$bundle_dir/packages/connector/lib/cli.js" pair-qr --config "$config_path"

pairing_page="http://127.0.0.1:3080/dsh-anywhere/v1/pairing"
attempt=0
while [ "$attempt" -lt 30 ]; do
  if /usr/bin/curl -fsS "$pairing_page" >/dev/null 2>&1; then
    break
  fi
  attempt=$((attempt + 1))
  sleep 1
done
open "$pairing_page" >/dev/null 2>&1 || true

echo
echo "DSH Anywhere is installed. The pairing page has been opened on this Mac."
