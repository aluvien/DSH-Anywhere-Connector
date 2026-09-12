# Relay deployment

The Relay is the public endpoint used by Connectors and iOS devices. It must run
on the server itself; do not proxy this domain directly to one user's Mac.

1. Copy `.env.example` to `.env` and replace the bootstrap token with at least
   32 random bytes.
2. Start the service:

   ```sh
   docker compose --env-file .env -f compose.yaml up -d --build
   ```

3. Add `nginx-location.conf` to the HTTPS server block for the Relay domain and
   reload Nginx.
4. Verify `https://your-relay.example/health` returns `{ "ok": true }`.

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
app or shared with end users. This JSON registry is appropriate for the first
private vertical slice only; migrate accounts and device records to PostgreSQL
before a public launch.
