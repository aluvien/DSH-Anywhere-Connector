# Relay deployment

The Relay is the public endpoint used by Connectors and iOS devices. It must run
on the server itself; do not proxy this domain directly to one user's Mac.

1. Copy `.env.example` to `.env`, replace the bootstrap token with at least
   32 random bytes, and set `DSH_RELAY_PUBLIC_URL` plus
   `DSH_RELAY_INSTALL_SOURCE_URL` to the public HTTPS Relay and the source
   archive that platform installers should deploy.
2. Start the service:

   ```sh
   docker compose --env-file .env -f compose.yaml up -d --build
   ```

3. Add `nginx-location.conf` to the HTTPS server block for the Relay domain and
   reload Nginx.
4. Verify `https://your-relay.example/health` returns `{ "ok": true }`.

When the two public installer URLs are configured, users install and register a
computer without receiving the bootstrap token:

```sh
# macOS
curl -fsSL https://your-relay.example/install | sh

# Linux
curl -fsSL https://your-relay.example/install-linux | sh
```

```powershell
# Windows PowerShell
irm https://your-relay.example/install-windows | iex
```

The returned script contains a random, short-lived enrollment token. Relay
limits issuance per source across all platforms, consumes the token before creating the machine, and
never persists or returns the administrator bootstrap token. Public enrollment
is disabled when the public URLs are omitted.

Once the Relay is healthy, register each Mac from the Connector host:

```sh
node packages/connector/lib/cli.js setup \
  --relay https://your-relay.example \
  --bootstrap-token '<admin bootstrap token>' \
  --machine-name 'Alice Mac'
```

The bootstrap token is only for this registration step. The generated machine
token stays in the Mac's 0600 `connector.json`; the generated pairing secret is
given to that Mac's iOS user. Do not put either value in the iOS binary or in
the public Relay configuration.

The bootstrap token can register machines and must never be shipped in the iOS
app or shared with end users. Anonymous one-command enrollment is deliberately
rate-limited but still allows anyone who can reach the Relay to create a machine
record; use it only when that product behavior is intended. This JSON registry
is appropriate for a small deployment; migrate records and abuse controls to a
database before operating at public-service scale.

The Relay can inspect plaintext messages while routing them; TLS protects the
links, but this is not end-to-end encryption. Treat the Relay host as trusted.
When Nginx fronts the container, set `DSH_RELAY_TRUSTED_PROXIES` to the exact
source IP address(es) Nginx uses to reach it (comma-separated). Forwarded client
addresses are ignored for every other peer so they cannot be spoofed to evade
pairing rate limits.
