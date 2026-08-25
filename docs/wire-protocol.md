# Native wire protocol

The native pizarra protocol is a small request/response protocol over TCP. It
uses one UTF-8 JSON object per line and is shared by `tiza`, `pzweb`, and the
hub. This page documents the stable concepts needed to build integrations; the
source remains authoritative for exact validation and error text.

## Framing

- A request or response is one JSON object followed by line feed (`LF`).
- Carriage returns are ignored, allowing `CRLF` senders.
- A line may not exceed 1 MiB.
- Ordinary connections carry one request and one response.
- The `watch` and `dial` commands upgrade the connection into a stream.
- Text values are JSON strings. Binary chunks are base64 strings.
- The transport is cleartext TCP. Authentication does not provide encryption.

The default one-shot client I/O deadline is 10 seconds. Clients must treat a
write that may have reached the hub followed by a missing response as an
unknown outcome, not as proof that the operation failed.

## Authentication and identity

Every ordinary request supplies a command, a credential, and normally an actor:

```json
{"cmd":"send","secret":"<identity-secret>","from":"builder","to":"reviewer","text":"Ready for review."}
```

There are two credential classes:

| Credential | Identity | Authority |
|---|---|---|
| Master credential | Normally `console` when `master_console_only = on` | Full administrative and messaging authority |
| Team credential | Bound to exactly one configured team | That team's normal commands plus explicitly delegated command families |

A team credential cannot claim another sender. When `from` is omitted, the hub
fills in its bound team. A credential may delegate selected administrative
families such as `task`, `workflow`, or `watch`; delegation does not turn it
into the master credential. The hub rejects an empty master credential, missing
team credentials, duplicate team credentials, and a team credential equal to
the master credential.

Keep secrets out of command lines, logs, URLs, browser bodies, and source
control. The shipped clients read them from protected configuration files.

## Common responses

Success has `ok:true` and may add command-specific data:

```json
{"ok":true}
```

Policy or validation rejection has `ok:false`:

```json
{"ok":false,"error":"description"}
```

When a mutating client knows that it wrote the request but cannot establish the
result, it exposes an `outcome` of `unknown`. Inspect current state before
retrying. Broadcasts and other fan-out operations may report partial success;
callers must inspect the returned counts.

## Messaging and inbox

Send one durable message:

```json
{"cmd":"send","secret":"<secret>","from":"builder","to":"reviewer","text":"Please inspect task 12."}
```

The destination may be a team, a configured group expression, or the console
where allowed. Direct success includes the assigned sequence and whether the
message is awaiting endpoint delivery:

```json
{"ok":true,"seq":42,"queued":false}
```

A broadcast returns a broadcast marker and queued count because each
destination receives its own durable journal entry.

Read an inbox page without consuming it:

```json
{"cmd":"inbox","secret":"<secret>","from":"reviewer","peek":true,"limit":50}
```

Useful inbox fields are:

- `peek`: do not advance the identity cursor;
- `all`: include acknowledged history without changing the cursor;
- `after`: page strictly after a sequence; its presence always makes the read
  non-consuming, including when the value is zero;
- `limit`: page size, default 50 and maximum 200.

Paged replies may include `more`. Acknowledge only a sequence that the identity
is entitled to consume:

```json
{"cmd":"ack","secret":"<secret>","from":"reviewer","upto":42}
```

The hub refuses acknowledgement beyond the last eligible message. This protects
the high-water mark from skipping unseen work.

Recent history is available with `cmd:"recent"`, `since`, and `max`. Team
credentials are filtered to their visible traffic before the result cap is
applied, unless they hold delegated watch authority.

## Administrative command families

The following families use the same authenticated JSON-line envelope. Prefer
the `tiza` CLI or the web API unless you are implementing a client library.

| `cmd` | Purpose | Typical operation selector |
|---|---|---|
| `task` | Durable task tree and notes | `add`, `state`, `assign`, `note`, `list`, `show`, `delete` |
| `workflow` | Dependency plans and recovery | `create`, `step`, `start`, `done`, `error`, `fixed`, `verify`, `abort`, `list`, `show`, `clone`, `insert`, `remove`, `set`, `history`, `undo`, `restore`, `delete` |
| `team` | Team registry | `add`, `set`, `show`, `remove`, `list` |
| `group` | Membership and group policy | `add`, `remove`, `show`, `list`, `boss`, `project`, `exclude`, idle policy and header operations |
| `project` | Project registry | `boss`, `show`, `list`, `remove` |
| `app` | Application ownership, manuals, projects, and history | `add`, `set`, `show`, `list`, `doc`, `history`, `undo`, `project`, `unproject`, `remove` |
| `header` | Delivery-envelope policy | `list`, `set`, `note` |
| `fleet` | Host/version inventory | command-specific fields |
| `backup` | Consistent state backup | destination and force fields |
| `update` | Fleet update request | team and force fields |
| `ver` | Hub protocol/release version | none |

Operation names are ordinary JSON fields produced by the public CLI builders.
Unknown fields, invalid types, invalid state transitions, and insufficient
authority are rejected rather than ignored.

## Watch stream

`watch` changes a connection from one-shot request/response into a live stream:

```json
{"cmd":"watch","secret":"<secret>","from":"observer","since":41}
```

The hub first writes `{"ok":true}` and then one JSON event per line. Event
types are:

| `ev` | Meaning | Important fields |
|---|---|---|
| `msg` | Durable message | `seq`, `ts`, `from`, `to`, `text`, `via`, optional `ident` |
| `sys` | System notice | `text` |
| `task` | Task/workflow notice | `text` |
| `alarm` | Activity or group-policy alarm | `team`, `text` |
| `ping` | Keepalive | implementation metadata may be present |
| `gap` | Replay can no longer certify continuity | `after`, `reason`, `reload:true` |

A normal team sees only traffic to or from itself. A credential with delegated
watch authority may receive the wider operational stream.

The four structural gap reasons are:

- `queue_overflow`: the live consumer fell behind its bounded queue;
- `replay_overflow`: replay produced more events than the stream could stage;
- `history_unavailable`: the requested cursor is older than available history;
- `cursor_ahead`: the requested cursor is beyond the hub's current journal.

After `gap`, discard any assumption of continuity and rebuild from a durable
read. Sequence gaps without a `gap` event are valid for scoped viewers because
messages between other identities are filtered out.

## Remote delivery

In direct-push mode, the hub opens a connection to a `tiza daemon` and sends a
delivery envelope:

```json
{"cmd":"deliver","secret":"<daemon-secret>","seq":42,"from":"builder","team":"reviewer","text":"<wrapped-message>"}
```

The daemon accepts only `deliver`, `ping`, `ver`, and `update`. It validates the
shared daemon credential, injects the message into the named terminal session,
persists the last injected sequence for that team, and acknowledges the exact
sequence. A repeated sequence is acknowledged without a second paste when the
receipt has already been persisted.

Current direct push presents the hub master credential to the remote daemon.
That expands the consequence of a remote-host compromise. Prefer reverse dial
unless the deployment specifically accepts this trust relationship.

## Reverse dial

With `dial = on`, the daemon opens the connection to the hub using its
identity-bound team credential:

```json
{"cmd":"dial","secret":"<team-secret>","from":"reviewer","teams":"reviewer","keepalive":60,"since":41,"ver":"<version>"}
```

The hub derives the allowed service scope from the bound credential; it does
not trust the claimed team list. The handshake reports accepted teams and may
report refused names:

```json
{"ok":true,"teams":"reviewer"}
```

The hub then sends `ping` and `deliver` objects on the long-lived connection.
For every delivery, the daemon must return an acknowledgement matching both the
team and sequence exactly. Pending messages are replayed after reconnection.
Only one active dial channel may serve a team at a time.

## Chunked file transfer

`put` and `get` carry files without a shared filesystem. Uploads include a
transfer ID, destination, base64 data, and exact offset. The final chunk adds
`last:true` and the SHA-256 digest of the complete file. Publication occurs only
after offset and digest verification.

Native chunks are at most 512 KiB and a transferred file is at most 10 MiB.
Receivers must treat the path returned by the hub as data, not as a shell
command.

## Compatibility rules

- `ver` reports the suite version and `caps` exposes capabilities used for
  compatibility checks.
- Additive response fields should be ignored by clients that do not need them.
- Unknown commands, operations, or required values must fail closed.
- Do not infer success from a closed socket.
- Do not retry a non-idempotent mutation after an unknown outcome until its
  durable state has been inspected.
- Never infer stream completeness solely from adjacent sequence numbers; honor
  explicit `gap` events.

See [Security](security.md) before implementing a network-facing client and
[Web API](web-api.md) for the browser-safe projection of this protocol.
