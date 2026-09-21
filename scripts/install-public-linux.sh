#!/bin/sh
set -eu

# Served by Relay after replacing these values with a short-lived enrollment
# grant and pinned public URLs. Usage: curl -fsSL <relay>/install-linux | sh

relay_url='__DSH_RELAY_URL__'
enrollment_token='__DSH_ENROLLMENT_TOKEN__'
source_archive_url='__DSH_SOURCE_ARCHIVE_URL__'

[ "$(uname -s)" = "Linux" ] || { echo "This installer requires Linux." >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "curl is required." >&2; exit 1; }
command -v tar >/dev/null 2>&1 || { echo "tar is required." >&2; exit 1; }
command -v systemctl >/dev/null 2>&1 || { echo "systemd is required." >&2; exit 1; }

support_dir="${XDG_CONFIG_HOME:-${HOME}/.config}/dsh-anywhere"
config_path="${support_dir}/connector.json"
runtime_dir="${support_dir}/runtime"
bundle_dir="${support_dir}/app"
temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/dsh-anywhere-install.XXXXXX")
next_bundle="${support_dir}/app.next.$$"
previous_bundle="${support_dir}/app.previous"

cleanup() { rm -rf -- "$temporary_dir" "$next_bundle"; }
trap cleanup EXIT HUP INT TERM
mkdir -p "$support_dir" "$runtime_dir"
chmod 700 "$support_dir" "$runtime_dir"

node_command=$(command -v node || true)
node_usable=0
if [ -n "$node_command" ] &&
   "$node_command" -e 'process.exit(Number(process.versions.node.split(".")[0]) >= 22 ? 0 : 1)' 2>/dev/null; then
  node_usable=1
fi

if [ "$node_usable" -ne 1 ]; then
  node_version=v22.19.0
  case "$(uname -m)" in
    x86_64|amd64) node_arch=x64 ;;
    aarch64|arm64) node_arch=arm64 ;;
    *) echo "Unsupported Linux architecture: $(uname -m)" >&2; exit 1 ;;
  esac
  node_home="${runtime_dir}/node-${node_version}-linux-${node_arch}"
  if [ ! -x "${node_home}/bin/node" ]; then
    node_archive="node-${node_version}-linux-${node_arch}.tar.xz"
    node_base="https://nodejs.org/dist/${node_version}"
    echo "Installing the private Node.js runtime…"
    curl -fsSL "${node_base}/${node_archive}" -o "${temporary_dir}/${node_archive}"
    curl -fsSL "${node_base}/SHASUMS256.txt" -o "${temporary_dir}/SHASUMS256.txt"
    expected_hash=$(awk -v name="$node_archive" '$2 == name { print $1 }' "${temporary_dir}/SHASUMS256.txt")
    if command -v sha256sum >/dev/null 2>&1; then
      actual_hash=$(sha256sum "${temporary_dir}/${node_archive}" | awk '{ print $1 }')
    elif command -v shasum >/dev/null 2>&1; then
      actual_hash=$(shasum -a 256 "${temporary_dir}/${node_archive}" | awk '{ print $1 }')
    else
      echo "sha256sum or shasum is required." >&2
      exit 1
    fi
    [ -n "$expected_hash" ] && [ "$expected_hash" = "$actual_hash" ] || {
      echo "Node.js download verification failed." >&2
      exit 1
    }
    extracted_node="${temporary_dir}/node"
    mkdir -p "$extracted_node"
    tar -xJf "${temporary_dir}/${node_archive}" -C "$extracted_node" --strip-components 1
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
curl -fsSL "$source_archive_url" -o "${temporary_dir}/source.tar.gz"
mkdir -p "$next_bundle"
tar -xzf "${temporary_dir}/source.tar.gz" -C "$next_bundle" --strip-components 1
pnpm --dir "$next_bundle" install --frozen-lockfile --config.confirmModulesPurge=false
pnpm --dir "$next_bundle" build

if [ -d "$previous_bundle" ]; then rm -rf -- "$previous_bundle"; fi
if [ -d "$bundle_dir" ]; then mv "$bundle_dir" "$previous_bundle"; fi
mv "$next_bundle" "$bundle_dir"

machine_name=$(hostname 2>/dev/null || uname -n)
if [ ! -f "$config_path" ]; then
  echo "Registering this Linux computer…"
  if ! DSH_ANYWHERE_ENROLLMENT_TOKEN="$enrollment_token" \
    "$node_command" "$bundle_dir/packages/connector/lib/cli.js" enroll \
      --relay "$relay_url" --machine-name "$machine_name" --config "$config_path"; then
    if [ -d "$previous_bundle" ]; then rm -rf -- "$bundle_dir"; mv "$previous_bundle" "$bundle_dir"; fi
    exit 1
  fi
fi

dsh_command="${tools_prefix}/bin/dsh"
if ! "$bundle_dir/scripts/install-linux-services.sh" \
    --config "$config_path" --node "$node_command" --dsh "$dsh_command"; then
  if [ -d "$previous_bundle" ]; then
    rm -rf -- "$bundle_dir"
    mv "$previous_bundle" "$bundle_dir"
    "$bundle_dir/scripts/install-linux-services.sh" \
      --config "$config_path" --node "$node_command" --dsh "$dsh_command" || true
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
  curl -fsS "$pairing_page" >/dev/null 2>&1 && break
  attempt=$((attempt + 1))
  sleep 1
done
if command -v xdg-open >/dev/null 2>&1; then xdg-open "$pairing_page" >/dev/null 2>&1 || true; fi

echo
echo "DSH Anywhere is installed and running for this Linux user."
