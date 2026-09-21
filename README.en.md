# DSH Anywhere

[简体中文](README.md) | [English](README.en.md)

DSH Anywhere lets you remotely use [DeepSeek Harness](https://github.com/deepseek-ai)
running on a macOS, Linux, or Windows computer from an iPhone. The computer
connects outward to a self-hosted Relay, so it does not need a public IP, port
forwarding, or a publicly exposed Harness port.

> [!IMPORTANT]
> iOS 17+ is currently the only supported mobile client. `android/` is an
> experimental prototype whose development is paused. It is outside the current
> code review, security review, acceptance, and release scope.

## Support status

| Component | Status | Notes |
|---|---|---|
| iOS app | Active development | The only supported mobile client |
| macOS Connector / Bridge | Active development | launchd user services |
| Linux Connector / Bridge | Active development | x64/arm64, systemd user services |
| Windows Connector / Bridge | Active development | Windows 10/11, current-user startup |
| Relay | Active development | Self-hosted authentication and message routing |
| Android app | Paused | Experimental code; not for production use |

The project is currently intended for personal use and controlled testing.
Accounts, organization-level permissions, public multi-tenant isolation,
end-to-end encryption, and large-scale operations are not complete.

## How it works

```text
iPhone ── HTTPS/WSS ──▶ Relay (your server) ◀── outbound WSS ── Connector
                                                                 │
                                                                 ▼
                                                      Bridge / Harness :3080
```

| Component | Runs on | Responsibility |
|---|---|---|
| iOS app | iPhone | Browse sessions, send messages and attachments, answer questions, and handle approvals |
| Relay | Self-hosted server | Register machines, pair devices, authenticate credentials, and route messages |
| Connector | macOS / Linux / Windows | Connect outward to Relay and forward requests and live events |
| Bridge | macOS / Linux / Windows | Expose local Harness capabilities to Connector |

Relay is part of the trust boundary. HTTPS/WSS protects data in transit, but the
current protocol is not end-to-end encrypted. Relay can read and validate routed
messages. It does not intentionally persist session contents.

## One-command installation

To use the project's current public Relay, run the command for the computer's
operating system.

### macOS

```sh
curl -fsSL https://dsh.biaozhu.me/install | sh
```

### Linux

x64, arm64, and systemd are supported:

```sh
curl -fsSL https://dsh.biaozhu.me/install-linux | sh
```

### Windows

Run this in Windows 10/11 PowerShell:

```powershell
irm https://dsh.biaozhu.me/install-windows | iex
```

The installer automatically:

1. prepares a private Node.js, pnpm, and DeepSeek Harness environment for the current user;
2. downloads and builds DSH Anywhere from a pinned Git commit;
3. registers the computer with a short-lived, single-use, source-bound enrollment grant;
4. installs and starts the Bridge and Connector background processes; and
5. prints a one-time QR code and opens the local pairing page.

The user does not need an account, Git, Homebrew, or manual Relay configuration.
Running the command again preserves the existing machine identity and updates the
local software. macOS uses launchd, Linux uses systemd user services, and Windows
uses current-user startup shortcuts with hidden restart supervisors.

Installer source files live in [`scripts/`](scripts/). Relay injects a random
one-time enrollment grant when a script is requested. That grant is never stored
statically in GitHub, an installer source file, or the user's configuration. The
administrator bootstrap token is never sent to user computers.

## Pair an iPhone

After installation, scan the QR code shown in the terminal or browser with the
iOS app. Its pairing code expires after ten minutes and can be used only once.
To pair another iPhone later, run the one-command installer for that operating
system again. It preserves the existing machine identity and issues a new QR code.

You can also open the local pairing page:

```text
http://127.0.0.1:3080/dsh-anywhere/v1/pairing
```

The pairing page accepts loopback connections only. Do not expose it through a
public reverse proxy.

## Self-host Relay

You need a Linux server with a domain, a valid TLS certificate, Docker Engine,
and the Docker Compose plugin.

```sh
git clone https://github.com/aluvien/DSH-Anywhere-Connector.git DSH-ANYWHERE
cd DSH-ANYWHERE/deploy/relay
cp .env.example .env
openssl rand -base64 48
```

Edit `.env` and set at least:

```dotenv
DSH_RELAY_BOOTSTRAP_TOKEN=the-random-value-generated-above
DSH_RELAY_PUBLIC_URL=https://your-domain.example
DSH_RELAY_INSTALL_SOURCE_URL=https://github.com/aluvien/DSH-Anywhere-Connector/archive/a-pinned-commit.tar.gz
```

Pinning a commit prevents public installers from downloading an unreviewed branch
update. Start Relay after saving the configuration:

```sh
chmod 600 .env
docker compose --env-file .env -f compose.yaml up -d --build
```

The container listens on `127.0.0.1:8787` by default. Publish it through an HTTPS
reverse proxy with WebSocket Upgrade support. See
[`deploy/relay/README.md`](deploy/relay/README.md) for the Nginx template and full
deployment instructions.

If the reverse proxy sends `X-Forwarded-For`, set `DSH_RELAY_TRUSTED_PROXIES` to
the exact source addresses the proxy uses to reach Relay. Relay ignores forwarded
headers from all other peers so clients cannot spoof their address to bypass
pairing or installer rate limits.

Verify the deployment:

```sh
curl -s https://your-domain.example/health
```

Both `ok` and `publicEnrollment` should be `true`.

## Build the iOS app

```sh
open ios/DSHAnywhere.xcodeproj
```

Select your Apple Developer Team in Xcode and install the app on an iPhone. QR
scanning requires a physical device; the simulator can use manual pairing.

## Current capabilities

- Pair, switch, manage, and revoke multiple computers and iPhones
- Organize sessions by workspace; create, open, rename, and archive sessions
- Render Markdown, code blocks, tables, tool calls, and streaming output
- Handle questions, approvals, permission modes, and model selection
- Send image and file attachments
- Simplified Chinese, English, and system-language selection
- Remote data as the source of truth, with local caching for faster startup and recovery

## Runtime and logs

### macOS

```sh
launchctl list | grep dsh-anywhere
curl -s http://127.0.0.1:3080/dsh-anywhere/v1/health
tail -f ~/Library/Logs/DSH\ Anywhere/connector.log
tail -f ~/Library/Logs/DSH\ Anywhere/bridge.log
```

### Linux

```sh
systemctl --user status dsh-anywhere-bridge dsh-anywhere-connector
journalctl --user -u dsh-anywhere-bridge -u dsh-anywhere-connector -f
curl -s http://127.0.0.1:3080/dsh-anywhere/v1/health
```

The installer attempts to enable systemd lingering for the current Linux user.
If host policy prevents a regular user from enabling it, the services still run
during that user's login session and start automatically on later logins.

### Windows

```powershell
Get-Content "$env:LOCALAPPDATA\DSH Anywhere\logs\connector.log" -Wait
Get-Content "$env:LOCALAPPDATA\DSH Anywhere\logs\bridge.log" -Wait
Invoke-WebRequest http://127.0.0.1:3080/dsh-anywhere/v1/health
```

When upgrading Relay, preserve `deploy/relay/.env` and the `relay-data` Docker
volume. Machine registrations and device credentials live in that volume, so a
normal `docker compose up -d --build` does not require pairing again.

## Development and validation

```sh
pnpm install
pnpm build
pnpm check
```

`pnpm check` runs type checking and tests for the protocol, Relay, Connector,
and Bridge plugin.

Unsigned iOS build check:

```sh
xcodebuild build-for-testing \
  -project ios/DSHAnywhere.xcodeproj \
  -scheme DSHAnywhere \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO
```

## Repository layout

```text
packages/
  protocol/             Shared message types and Zod validation
  relay-server/         Machine registration, pairing, authentication, and routing
  connector/            Cross-platform outbound connection, command forwarding, and CLI
  dsh-anywhere-plugin/  Harness Bridge, session API, events, and local pairing page
ios/DSHAnywhere/        The currently supported iOS client
android/                Paused experimental Android prototype
deploy/relay/           Docker Compose, Dockerfile, and Nginx configuration
scripts/                Platform installers, background services, and release helpers
```

`RELAY_SCHEMA_REVISION` is defined in `packages/relay-server/src/server.ts`.
Whenever a routed shared message changes, bump the revision and redeploy Relay.

## Security boundary and known limitations

- Relay can read routed plaintext messages; end-to-end encryption is not implemented.
- Relay persists machine and device registrations, but not session contents by design.
- Connector and Bridge can operate the local Harness on the user's behalf and should run only on a user-controlled computer.
- Enrollment grants and pairing codes are protected by expiration, single use, source binding, and rate limits.
- Local credential files should remain readable only by the current user. Never expose the loopback pairing page publicly.
- The current single-file JSON registry is suitable for personal or small controlled deployments, not a public multi-tenant service.
- Accounts, organizations, permission tiers, and public multi-tenant isolation are incomplete.
- Linux requires systemd; Windows background processes start after the current user logs in.
- `dshanywhere://` is not exposed as a general-purpose system deep link.
- Android has not passed the current security review and must not handle production or sensitive data.

Before Android development resumes, its product scope and protocol compatibility
target must be confirmed again. The `android/` tree also needs an independent
code, security, and privacy review; unit, integration, physical-device, and
network-failure tests; and restored release gates.
