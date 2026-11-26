# @sarto/wire

The wire protocols a Sarto server and its clients share, with no dependencies:

| Module   | What it holds                                                   |
| -------- | --------------------------------------------------------------- |
| `relay`  | relay protocol 1: messages, limits, close codes, host sign-in   |
| `push`   | the push gateway's signed request                               |
| `prices` | the daily model price snapshot and how a server cuts it         |
| `sync`   | end-to-end encrypted sync: scopes, envelopes, keybags, approval |
| `codec`  | the base64url and JSON helpers the modules above share          |

[PROTOCOL.md](./PROTOCOL.md) is the specification.

Licensed under Apache-2.0 (see [LICENSE](./LICENSE) and [NOTICE](./NOTICE)), unlike the rest of this
repository, so that servers and clients under any license can speak the protocol. Contributions to
this folder are accepted under Apache-2.0.

The Sarto server's test suite exercises these modules, and `src/shared/remote/sarto-wire-parity.test.ts`
in the Sarto repository checks them against the daemon's own implementation of the protocol.
