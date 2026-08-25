# Web console

`pzweb` is the browser control surface for the pizarra hub. It serves the
bundled application and exposes an authenticated HTTP adapter to the native bus.
It does not read or mutate the hub's state files directly.

## Views

The browser application is one document with eight focused views:

| View | What it provides |
|---|---|
| Activity | Live durable messages, direction filters, connection state, session counters, and explicit gap warnings |
| History | Paged message journal with summaries and on-demand full bodies |
| Inbox | Non-consuming unread view, optional acknowledged history, and explicit read acknowledgement |
| Files | One-level shared-directory browser with guarded deletion |
| Transfers | Chunked download/upload with progress and final SHA-256 verification |
| Workflows | Searchable plans, dependency map, state details, editing, lifecycle operations, and history |
| Tasks | Filtered work board, cards, notes, assignment, state changes, creation, and guarded deletion |
| Structure | Teams, groups, projects, and applications, including ownership, group permission-block policy, relations, manuals, and history |

The Activity view receives new durable messages without reloading. History and
Inbox remain separate because "look at it" and "mark it read" are different
operations.

The [README gallery](../README.md#screenshots) shows every view rendered by the
real browser application with synthetic data. It includes separate team, group,
and application registries plus an animated scroll through a larger workflow
dependency map.

## Startup contract

Before binding an HTTP socket, `pzweb` verifies all of the following:

1. Its configuration exists, has no symlink in its path, and has permissions
   exactly `0600`.
2. `listen` is a non-wildcard IPv4 address.
3. `allow_from` contains only well-formed IPv4 or CIDR rules.
4. `host` is set and `origin` is exactly coherent with it over cleartext HTTP.
5. A Basic-authentication username and 64-hex SHA-256 password digest are set.
6. The static asset tree exists, has no symlink component, and satisfies asset
   size/type limits.
7. The optional shared-file root is absolute, exists, and has no symlink
   component.
8. The hub answers using the configured identity-bound credential.
9. That credential cannot impersonate `console`.
10. The bound team has all administrative families required by the console.

The required delegated families are:

```text
team group project app task workflow watch backup update header
```

This all-or-nothing startup rule prevents a console that appears healthy but
fails only when a particular operation is selected.

## Recommended local configuration

Create the web identity in the hub's authoritative SQLite registry. Do not add a
`[team:*]` section to `pizarra.conf`:

```sh
tiza team add pzweb "Private operational web console" --session -
tiza team set pzweb secret --file /secure/pzweb-team.secret
tiza team set pzweb delegate \
  "team,group,project,app,task,workflow,watch,backup,update,header"
```

Web server:

```ini
[pizarra]
host = 127.0.0.1
port = 7010
secret = <unique-web-team-secret>
self = pzweb

[web]
listen = 127.0.0.1
port = 7080
allow_from = 127.0.0.1
host = 127.0.0.1:7080
origin = http://127.0.0.1:7080
static = /usr/local/share/pizarra/web/apps
; shared = /mnt/pizarra-shared
user = operator
password_sha256 = <64-lowercase-hex-digest>
```

Apply exact permissions and start:

```sh
chmod 600 /etc/pizarra/pzweb.conf
pzweb --config /etc/pizarra/pzweb.conf
```

The password digest belongs in the file; the browser login uses the original
password.

## Request boundaries

All requests, including static assets and error paths, require:

- a source address admitted by `allow_from`;
- the exact configured `Host` header;
- valid HTTP Basic credentials.

All mutations additionally require:

- `POST`;
- exact configured `Origin`;
- `Content-Type: application/json`;
- `X-Pizarra: 1`;
- an object body no larger than 64 KiB;
- no unknown, duplicated, or incorrectly typed fields.

The server emits no CORS permission and rejects `OPTIONS`. It currently speaks
cleartext HTTP directly and is not proxy-aware. See [Security](security.md).

## Live activity

`GET /api/feed` opens a Server-Sent Events stream. It accepts a resume cursor
from `Last-Event-ID` or, when that header is absent, `?since=<seq>`.

The browser receives:

- `message`: `{ev, seq, ts, from, to, text, dir}`, where `dir` is `in`, `out`,
  or `other`;
- `gap`: `{ev, after, reason}`, which terminates the stream and requires a
  durable reload;
- `bye`: a terminal protocol/closing event;
- SSE comments used as keepalives.

The web feed intentionally projects durable message events. Native system and
task watch events are not included in this view. A jump in global sequence
numbers is not itself loss, because an identity may be scoped away from messages
between other participants. Only `gap` declares an incomplete view.

The browser maintains at most the most recent 300 live messages in a tab. Use
History for durable pagination.

Message bodies are rendered only through text nodes. Terminal CSI styling is
removed before display (including the replacement form produced at the JSON
control-character boundary); the browser never interprets terminal escapes as
markup or control instructions.

## Files and transfers

When `[web] shared` is configured, `pzweb` can:

- list the exchange root and one exact team directory level;
- download a named shared path in chunks;
- upload base64 chunks with an explicit upload ID and offset;
- publish only after the hub verifies the whole-file digest;
- delete a named entry through descriptor-anchored, no-follow operations.

Its value must exactly match the hub's `[shared] dir` and expose the same
external mount. The tree is outside the built-in backup/restore boundary; pzweb
does not create a second copy. Keep credentials and backup bundles out of it.

Normal deletion of a non-empty directory is rejected with a count. Recursive
deletion must be explicitly requested and may report a partial outcome if an
entry changes during the operation. Symlinks are never followed; deleting a
symlink deletes the link itself.

## Failure semantics

The browser API separates four important outcomes:

- **Rejected**: the hub answered `ok:false`; the requested change did not pass
  its policy.
- **`not_sent`**: the adapter could not write the request; retry is safe.
- **`unknown`**: the request was written but its acknowledgement was lost or
  malformed; do not repeat it until current state has been re-read.
- **`applied_stale`**: the mutation was acknowledged, but the follow-up card
  refresh failed; the mutation is applied and the view must be reloaded.

This distinction prevents a lost response from turning into a duplicated
message, task, or workflow change.

## Resource controls

The implementation caps:

- 256 simultaneous HTTP connections globally;
- 64 connections per source address;
- 16 live SSE feeds per source address;
- 64 KiB request bodies;
- 2 MiB per static asset and 32 MiB for the complete static tree;
- hub calls to a 12-second total budget.

Static assets are loaded into memory at startup and served with content-derived
ETags. Security headers include a same-origin Content Security Policy,
`nosniff`, `no-referrer`, and frame denial.

## Registry and service boundaries

Structure, history, task, workflow, and application HTTP handlers construct
native bus requests and project the hub replies. `pzweb` never opens
`/var/lib/pizarra/org.sqlite`, reads registry INI sections, or maintains a local
copy of organization state. Restarting `pzweb` therefore does not reload a
second registry; current cards always come from `pizarra`.

An example `systemd/pzweb.service` is included. Its shipped `root:root` setting
matches the current consolidated deployment and migration default; it reads
`/etc/pizarra/pzweb.conf` and assets below
`/usr/local/share/pizarra/web/apps`. A dedicated `pzweb` account is preferable
for a new installation, but the file owner, service `User`/`Group`, and
`PZWEB_OWNER`/`PZWEB_GROUP` migration settings must be changed together. Review
every path, address, and permission before enabling it. The service account
needs:

- read access to its mode-`0600` `pzweb.conf` and installed web assets;
- network access to the hub;
- optional access to the shared root, granted narrowly with a dedicated group
  or ACL and without access to the hub config or store;
- no general interactive or administrative OS access beyond those needs.

Use the HTTP interface only on a trusted private network. A successful login is
not transport encryption.
