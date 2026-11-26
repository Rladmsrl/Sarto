# Sarto wire protocols

What a Sarto server and its clients say to each other: the relay that joins devices to hosts, the
push gateway, the daily price snapshot and end-to-end encrypted sync. Each section states the
messages, limits and checks a conforming side follows.

All text is UTF-8. "base64url" is RFC 4648 section 5 without padding; a decoder refuses any other
character and any length whose remainder by 4 is 1.

## 1. Relay, protocol 1

### 1.1 Discovery

`GET /v1` answers JSON:

```json
{
  "relay": "sarto",
  "protocol": 1,
  "regions": [{ "id": "main", "url": "https://..." }],
  "features": ["hosts"]
}
```

- `relay` is the literal `sarto` and `protocol` is `1`; clients refuse anything else.
- A region `id` matches `^[a-z0-9][a-z0-9-]{0,31}$`, its `url` is an http or https origin, and a
  client reads at most 8 regions.
- `features` holds at most 8 strings of 1 to 32 characters. Defined features:
  - `hosts`: the relay accepts host profiles and lists them on `GET /v1/hosts`
  - `drain`: the relay tells sockets that asked when the region is being emptied
  - `relay-tokens`: the relay accepts relay tokens from the account service as access tokens
  - `sarto-sync`: the server also offers Sarto sync (section 4)
- A server may also include an optional `serverVersion` string (for diagnostics only); clients ignore unknown discovery fields and never use software versions for wire compatibility.

An origin is the scheme, host and port of an `http:` or `https:` URL without credentials. A socket
URL is the origin with `http` replaced by `ws` (so `https` becomes `wss`) followed by the path.

### 1.2 Identities

A host holds an Ed25519 key. Its relay id is the first 16 bytes of the SHA-256 of the 32-byte raw
public key, in lowercase RFC 4648 base32 without padding: 26 characters of `[a-z2-7]`.

Tokens and nonces the relay hands out are 32 random bytes in base64url; a received one matches
`^[A-Za-z0-9_-]{16,128}$`. An access token is any non-empty string of at most 4096 characters.

### 1.3 Sockets and paths

| Path                               | Opened by | Purpose                                 |
| ---------------------------------- | --------- | --------------------------------------- |
| `WS /v1/hosts/<id>`                | host      | control socket                          |
| `WS /v1/hosts/<id>/connect`        | device    | asks to be joined to the host           |
| `WS /v1/hosts/<id>/accept/<token>` | host      | the host's end of one device's tunnel   |
| `GET /v1/hosts`                    | device    | lists the account's hosts (bearer auth) |

Every text message is one JSON object of at most 65536 bytes. Any socket may send the text `ping`,
which the relay answers with `pong`. Binary messages on a joined tunnel pass unchanged in both
directions and are at most 65536 bytes; a larger message closes the socket with 1009.

### 1.4 Host sign-in

1. The relay sends `{"type":"challenge","nonce":<token>}`.
2. Within 10 s the host sends `{"type":"sign-in","publicKey":<b64url 32 bytes>,"signature":<b64url 64 bytes>,"token":<access token>}`.
3. The signature is Ed25519 over the four lines `sarto-relay/1`, the relay origin, the host id and
   the nonce, joined by `\n` with no trailing newline. The relay checks that the key hashes to the
   id in the path, that the signature verifies, and that the token belongs to a signed-in account.
4. The relay answers `{"type":"ready"}`. A second sign-in for the same id replaces the first, which
   receives `{"type":"replaced"}` and is closed with 4409.

After `ready` the host may send:

- `{"type":"token","token":<access token>}` to renew its token in place. A lapsed token is still
  accepted for 5 minutes past its expiry.
- `{"type":"profile","profile":<profile>|null}` to be listed to its account's devices, or to stop.

A profile is `{"key","name","platform"}`: `key` is the host's X25519 channel key, 32 bytes in
base64url; `name` is 1 to 64 characters, already trimmed, with no C0, C1 or DEL control character;
`platform` matches `^[a-z0-9_-]{1,32}$`. A host builds its name by removing control characters,
trimming, keeping whole characters up to 64 UTF-16 units and trimming again.

### 1.5 Device connect

1. The device opens `/v1/hosts/<id>/connect` and within 10 s sends
   `{"type":"connect","token":<access token>,"features":["drain"]}`. `features` is optional; the
   relay keeps at most 8 strings of 1 to 32 characters.
2. The relay checks the token is for the host's account and sends the host
   `{"type":"incoming","token":<one-time token>}`.
3. Within 10 s the host opens `/v1/hosts/<id>/accept/<token>`. The relay joins the two sockets and
   sends the device `{"type":"joined"}`.
4. At most 16 devices are joined to one host at once.

A relay with `drain` may send `{"type":"drain"}` to a ready host or to a joined device that asked.

### 1.6 Close codes

| Code | Reason       | Meaning                                                          |
| ---- | ------------ | ---------------------------------------------------------------- |
| 4400 | malformed    | a message is malformed or out of turn                            |
| 4401 | unauthorized | wrong key, bad signature, lapsed token or removed device         |
| 4403 | forbidden    | the device's token is missing or for another account             |
| 4404 | offline      | the host is not signed in, did not accept, or the token is wrong |
| 4408 | timeout      | no sign-in or connect in time                                    |
| 4409 | replaced     | another sign-in took this one's place                            |
| 1009 | too_big      | a message over 65536 bytes                                       |
| 4429 | too_many     | too many connections at once or in a minute                      |

### 1.7 Host list

`GET /v1/hosts` with `Authorization: Bearer <access token>` answers `{"hosts":[...]}` with at most
64 entries, each a profile plus its `id`. A client refuses the whole answer if any entry is invalid.

## 2. Push gateway

A host posts `POST /v1/push` with:

- `Authorization: Bearer <access token>`
- `Content-Type: application/json`
- `Sarto-Host-Key`: the host's Ed25519 public key, base64url
- `Sarto-Signature`: Ed25519 over the four lines `sarto-push-request/1`, the gateway origin, the
  host id and the exact request body, joined by `\n`

The body is at most 8192 bytes of JSON:

```json
{ "time": 1760000000000, "token": "<hex>", "environment": "production", "push": { ... } }
```

- `time` is a non-negative safe integer in ms since the epoch, within 5 minutes of the gateway's clock.
- `token` is an APNs device or Live Activity token: 16 to 200 bytes as lowercase hex.
- `environment` is `production` or `sandbox`.
- `push` is one of the following. `sealed` and `attributes` are base64url of at most 3000 characters.
  `collapse` matches `^[A-Za-z0-9_-]{1,64}$`.
  - `{"type":"alert","sealed","collapse"}`
  - `{"type":"background","sealed"}`
  - `{"type":"liveactivity","event":"start","sealed","attributes"}`
  - `{"type":"liveactivity","event":"update"|"end","sealed"}`

A refusal answers `{"error":<reason>}`: 400 `malformed`, 401 `unauthorized`, 403 `signed_out`,
410 `unregistered`, 413 `too_big`, 429 `too_many`, 502 `apns`, 503 `unavailable`.

The gateway never opens `sealed`: it is sealed by the host to the device's key.

## 3. Price snapshot

`GET /v1/prices` answers the day's snapshot of API list prices:

```json
{
  "asOf": "2026-11-24",
  "models": {
    "<model key>": { "input": 0.000003, "output": 0.000015, "cacheRead": 0, "cacheWrite": 0 }
  }
}
```

- `asOf` is `YYYY-MM-DD`.
- `models` holds 100 to 20000 entries, keyed by non-empty strings of at most 200 characters.
- Each price is dollars per token, a finite number in `[0, 1)`: `input`, `output`, `cacheRead`,
  `cacheWrite`, and optionally `cacheWrite1h`.

The server cuts the snapshot from LiteLLM's `model_prices_and_context_window.json`:

- Only entries whose `mode` is `chat` and that have numeric `input_cost_per_token` and
  `output_cost_per_token` are taken. `cache_read_input_token_cost` and
  `cache_creation_input_token_cost` default to 0; `cache_creation_input_token_cost_above_1hr`
  becomes `cacheWrite1h` when it is a finite number.
- The model key is derived from the entry name. Lowercase and trim it. Drop one trailing `[...]`
  group. Split on `/` and drop empty parts. If more than one part remains and the last is an
  effort (`minimal`, `low`, `medium`, `high`, `xhigh`, `max`, `none`), drop it. Keep the last part.
  Drop a trailing `-YYYYMMDD` or `-YYYY-MM-DD` date. An empty key is skipped.
- When two names give the same key, a name without `/` beats one with `/`. Between two of the same
  kind, the one that sorts first by UTF-16 code units wins.
- Keys appear in sorted order.

## 4. Sync

The sync types and checks are in [`src/sync.ts`](./src/sync.ts), which is the normative definition:
scopes, encrypted envelopes, Keybag v2, device and recovery key wraps, approvals, manifests
and records. The server stores envelopes as opaque ciphertext and validates only their shape.

The server is not trusted with the sync master key (SMK). It stores and relays everything below,
and a device never takes an SMK, nor hands one out, on the server's word alone.

### 4.1 Approving a device

A device (N) that has signed in to an account whose keybag (v2) does not hold it asks a device that
does (A) to seal the SMK to N's X25519 sync key. Both show a code, which the user compares on both;
the exchange below lets neither the server nor anyone else choose a key whose code matches.

1. N picks 32 random bytes `nN` and posts `POST /v1/sync/approvals` with its `deviceId`,
   `devicePublicKey`, `deviceName`, `platform`, optional `targetApproverDeviceId` (when the user
   picked a specific existing device to approve it) and `commitment` = SHA-256(`sarto-approval-v2/commit`,
   LF, `devicePublicKey`, LF, base64url(`nN`)). Posting the same commitment again refreshes the
   request; another commitment starts the request over, dropping any answer and reveal.
2. A, holding the SMK (and matching `targetApproverDeviceId` when set), picks 32 random bytes `nA` and posts
   `POST /v1/sync/approvals/<deviceId>/answer` with `approverDeviceId`, `approverPublicKey` (A's
   X25519 sync key), `approverName` and `nonce` = base64url(`nA`). The server keeps the first
   answer; only the same approver may answer again, and only before the reveal.
3. N, once it reads an answer, posts `POST /v1/sync/approvals/<deviceId>/reveal` with `nonce` =
   base64url(`nN`). N reveals `nN` for one answer only: an answer that changes afterwards starts a
   new request with a new nonce. A checks the reveal against the commitment it answered.
4. Both show the code: the first 40 bits of SHA-256(`sarto-approval-v2/code`, LF, account id, LF,
   N's key, LF, A's key, LF, base64url(`nN`), LF, base64url(`nA`)), as 8 Crockford base32 characters
   in two groups of four. The user confirms on N that the codes match, and approves on A.
5. A seals the SMK to N's key and adds `approval` to the wrap (section 4.2) before posting it to
   `POST /v1/sync/keybag/devices`. N takes the SMK only from a wrap whose `approval` names the key of
   the device the user confirmed on N.

The server sends `sync.approval.updated` with the `deviceId` on the account's sync stream when an
answer or a reveal arrives. A request without a commitment is one from an earlier client, which a
device holding the SMK does not approve.

### 4.2 Wrap approvals

`approval` = `{approverDeviceId, approverPublicKey, mac}`. The MAC key is HKDF-SHA256 over the
X25519 shared secret of the approver's and the wrap device's sync keys, with the salt
`sarto-keybag-v2/approval-salt` and the info `sarto-keybag-v2/approval`, LF, `approverPublicKey`,
LF, `devicePublicKey`. `mac` = HMAC-SHA256 over `sarto-keybag-v2/approval`, LF, account id, LF,
`deviceId`, LF, `keyEpoch`, LF, `ephemeralPublicKey`, LF, `iv`, LF, `wrappedKey`. Only the
approver and the wrap's device can compute it. A device sealing the SMK to itself names its own key
as the approver.

### 4.3 Blobs

Blobs are content-addressed ciphertext an envelope refers to, such as a skill's archive:
`PUT`, `HEAD` and `GET /v1/sync/blobs/<sha256>`, the SHA-256 of the bytes in lowercase hex. They
count against the account's quota. A device approved for the keybag removes a blob nothing refers
to any more with `DELETE /v1/sync/blobs/<sha256>`: `204` once the account no longer holds it, `404`
when it held none by that hash, `403` from a device not in the keybag. The server cannot read
envelopes, so it never removes a blob by itself: the devices do, and a device that refers to a blob
again first checks with `HEAD` that it is still there, uploading it again when it is not.

### 4.4 Reset

The account's owner may reset sync on the server's own pages, as when every device has left and the
recovery key is lost. The server then removes the account's keybag, scopes, items, approvals and
blobs, and sends `{"type": "sync.reset"}` on the account's sync stream. A device that gets it, or
finds the manifest's `keybag` null while it holds a key, forgets the key and its replica, and sync
starts over as on a new account: the first device to set it up makes a new keybag, and the others
ask it for approval.

## 5. Problem Reports

Types, limits and helpers live in [`src/reports.ts`](./src/reports.ts).

| Endpoint                             | Auth                                  | Purpose                                              |
| ------------------------------------ | ------------------------------------- | ---------------------------------------------------- |
| `POST /api/v1/reports`               | Bearer `access`, web session, or none | Submits a report (`multipart/form-data` or JSON)     |
| `GET /api/v1/reports`                | Bearer `access` or web session        | Lists the account's reports (`scope=all` for owner)  |
| `GET /api/v1/reports/<id>`           | Bearer `access` or web session        | Reads report detail, timeline and comments           |
| `GET /api/v1/reports/<id>/bundle`    | Bearer `access` or web session        | Downloads the private ZIP bundle (reporter or owner) |
| `POST /api/v1/reports/<id>/comments` | Bearer `access` or web session        | Posts a comment on the report                        |
| `PATCH /api/v1/reports/<id>`         | Owner only                            | Updates status, `issueUrl`, `fixedInVersion`, `note` |
| `DELETE /api/v1/reports/<id>`        | Reporter or owner                     | Deletes the report and its stored ZIP bundle         |

- Report IDs match `^SR-[A-Z0-9]{6}$` (excluding `0/O/1/I/L`).
- ZIP bundles are at most 50 MiB, with at most 500 entries and entry names of at most 260 characters;
  the server inspects the Central Directory without decompressing any member and rejects `..` steps.
- An invalid or expired `Authorization` header on `POST /api/v1/reports` always answers `401`
  `{"error":"unauthorized"}` so signed-in clients refresh and retry; only requests with no
  `Authorization` header and no web session are accepted as anonymous (`accountId = "anonymous"`),
  which only maintainers (`role = "owner"`) may inspect or delete.
