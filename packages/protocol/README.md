# @dsh-anywhere/protocol

The versioned JSON wire contract shared by the native iOS client and the
DeepSeek Harness companion. `src/index.ts` exports Zod schemas, inferred
TypeScript types, and parse helpers.

Every event has `version`, `messageId`, `machineId`, `deviceId`, `sequence`,
and `timestamp`. Commands carry a `requestId` rather than an event sequence.
Event sequence numbers are positive integers and must be strictly increasing
within one stream. Pairing messages use a six-digit, one-time code and are
intentionally separate from the session event stream.

Run tests with:

```sh
pnpm install
pnpm test
pnpm typecheck
```
