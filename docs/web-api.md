# Web API

`pzweb` exposes a strict same-origin JSON API under `/api/` and one SSE stream.
It is an adapter over the native hub protocol: the server supplies the bus
credential, actor identity, and command. Browser bodies may not contain
`secret`, `from`, or `cmd`.

## Authentication and common rules

Every route and static asset requires HTTP Basic authentication. The request
must also arrive from an admitted IPv4/CIDR source and carry the exact configured
`Host` value.

Read routes use `GET`. Mutations use `POST` and require:

```http
Origin: http://configured-authority
Content-Type: application/json
X-Pizarra: 1
```

Mutation bodies must be JSON objects. Duplicate keys, unknown keys, wrong JSON
types, query parameters on write routes, encoded path separators, backslashes,
NUL, and dot segments are rejected. `OPTIONS` and CORS are not supported.

## Response envelope

Normal success:

```json
{"ok": true, "data": {}}
```

Normal error:

```json
{"ok": false, "error": "description", "fix": "actionable correction"}
```

Transport/projection failures may include:

| `outcome` | Meaning | Client action |
|---|---|---|
| `not_sent` | The hub request was not written | Retry is safe |
| `unknown` | It was written but the result cannot be established | Re-read state; do not blindly retry |
| `upstream_malformed` | A read reply could not be projected safely | Report protocol drift; no write occurred |
| `applied_stale` | The mutation succeeded but refreshed data is unavailable | Reload; do not repeat the mutation |

Hub timeouts return `504` and a `Retry-After: 5` header. Connection/protocol
failures normally return `502`. Validation uses `400`, authentication `401`,
authorization/origin `403`, method mismatch `405` with `Allow`, conflicts `409`,
body limits `413`, media type `415`, rate limits `429`, and unavailable optional
features `501`.

## Read routes

All unlisted query parameters and repeated parameters are rejected.

| Route | Query | Data |
|---|---|---|
| `GET /api/help` | none | Runtime route help used by the browser |
| `GET /api/feed` | `since` optional; `Last-Event-ID` takes precedence | SSE stream |
| `GET /api/teams` | none | Team list with open-task and activity facts |
| `GET /api/team/<name>` | none | One team card |
| `GET /api/groups` | none | Group list |
| `GET /api/projects` | none | Project list |
| `GET /api/project/<name>` | none | Project, assignments, and application roles |
| `GET /api/apps` | none | Application list |
| `GET /api/app/<name>` | none | One application card |
| `GET /api/app/<name>/doc` | `at=<history-id>` optional | Current or historical plain-text manual |
| `GET /api/app/<name>/history` | none | Application history text |
| `GET /api/tasks` | `filter`, `team` optional | Tasks; default filter is open |
| `GET /api/task/<id>` | none | Task card and direct subtask IDs |
| `GET /api/workflows` | none | Workflow list |
| `GET /api/workflow/<name>` | none | Workflow card and rendered tree |
| `GET /api/workflow/<name>/history` | none | Snapshot history |
| `GET /api/messages` | `since`, `limit=1..200` optional | Durable message page; newest page when `since` is absent |
| `GET /api/message/<seq>` | none | A zero-or-one full-message array |
| `GET /api/inbox` | `all`, `after`, `limit=1..200` optional | Non-consuming inbox page and optional `more` count |
| `GET /api/files` | none | Shared root entries/directories |
| `GET /api/files/<team>` | none | One exact directory level |
| `GET /api/download` | `path` required; `offset`, `max` optional | Verified download chunk fields |
| `GET /api/fleet` | none | Host kind, address, online state, version, and teams |
| `GET /api/version` | none | Hub version |
| `GET /api/header` | none | Current delivery-header configuration |

Task `filter` accepts `open`, `done`, `all`, `superseded`, `cancelled`,
`waiting`, or `error`. `team` accepts one team, not a group expression.

Inbox reads are always peeks. `after` is the last sequence already held by the
client. The server returns oldest unread entries first and a `more` count when a
page does not reach the current end.

## SSE contract

The connection starts with `retry: 5000`. Message events are:

```text
id: 42
event: message
data: {"ev":"msg","seq":42,"ts":"...","from":"builder","to":"pzweb","text":"...","dir":"in"}
```

`dir` is `out` when `from` is the web identity, `in` when `to` is the web
identity, and `other` for traffic between third parties visible through the
delegated watch scope.

A structural gap terminates the stream:

```text
event: gap
data: {"ev":"gap","after":41,"reason":"replay_overflow"}
```

Reasons are `queue_overflow`, `replay_overflow`, `history_unavailable`, and
`cursor_ahead`. Clients must reload a durable view rather than infer missing
events.

## Core mutations

Body fields in braces are optional. An empty object is written as `{}`.

| Route | JSON body | Result |
|---|---|---|
| `POST /api/message` | `to`, `text` | Direct `{seq,queued}` or broadcast counts |
| `POST /api/task` | `team`, `title`, `{milestone,parent}` | Created task card |
| `POST /api/task/<id>/state` | `state` | Updated task card |
| `POST /api/task/<id>/note` | `text` | Updated card with note |
| `POST /api/task/<id>/assign` | `team` | Updated card; empty string unassigns |
| `POST /api/task/<id>/delete` | `{}` | `{removed:<id>}` |
| `POST /api/inbox/ack` | `upto` | `{acked:<seq>}` |
| `POST /api/header` | `key`, `value` | Current header configuration |

The acknowledgement endpoint refuses a cursor above the oldest unread window
shown by the hub, because an acknowledgement advances a high-water mark for
everything below it.

## Workflow mutations

| Route | JSON body | Effect |
|---|---|---|
| `POST /api/workflow` | `name`, `group` | Create an empty draft |
| `POST /api/workflow/<name>/step` | `team`, `milestone`, `{after,eta}` | Append a draft step |
| `POST /api/workflow/<name>/insert` | `team`, `milestone`, `after`, `{eta}` | Splice after one step |
| `POST /api/workflow/<name>/start` | `{}` | Start roots |
| `POST /api/workflow/<name>/done` | `{step,proof}` | Complete an active step |
| `POST /api/workflow/<name>/error` | `why`, `{step}` | Halt the workflow |
| `POST /api/workflow/<name>/fixed` | `text` | Record repair and testing |
| `POST /api/workflow/<name>/verify` | `result`, `{note}` | `result` is `ok` or `fail` |
| `POST /api/workflow/<name>/abort` | `why` | Abort a running workflow |
| `POST /api/workflow/<name>/delete` | `{}` | Delete an eligible workflow |
| `POST /api/workflow/<name>/set` | `field`, `value` | Set plan `strict` or `eta` |
| `POST /api/workflow/<name>/step/<n>/set` | `field`, `value` | Set `team`, `milestone`, `after`, or `eta` |
| `POST /api/workflow/<name>/step/<n>/remove` | `{}` | Splice out a draft step |
| `POST /api/workflow/<name>/undo` | `{snapshot}` | One-step undo or named snapshot |
| `POST /api/workflow/<name>/restore` | `data` | Restore a complete saved card |
| `POST /api/workflow/<name>/clone` | `to`, `{group}` | Clone into a new draft |

`step` in a completion/error body is a positive JSON integer or the string `-`
for the actor's single active step. `after` on append is a dependency expression;
`after` on insert is one JSON step number. Milestone titles are limited to 120
characters and proof/error/fix text to 4096 characters.

`milestone` is the canonical English request field. For compatibility with
clients older than 1.2, these routes also accept the legacy request field
`hito`, but never both spellings in one body. Hub responses and durable hub
records retain `hito` as their established wire/storage field; pzweb adapts the
workflow read model to the documented response schema.

## Organization and application mutations

| Route | JSON body | Effect |
|---|---|---|
| `POST /api/team` | `name`, `{speciality,parent,host,session,launch,prompt}` | Create team |
| `POST /api/team/<name>/set` | `field`, `value` | Update one exposed field |
| `POST /api/team/<name>/remove` | `{}` | Remove team if integrity rules allow |
| `POST /api/group` | `name`, `members` array | Create group |
| `POST /api/group/<name>/remove` | `{members}` array | Remove members, or delete group when omitted |
| `POST /api/group/<name>/boss` | `{boss}` | Replace/clear group administrator |
| `POST /api/group/<name>/project` | `{project}` | Replace/clear project label |
| `POST /api/group/<name>/exclude` | `{excluded}` string | Replace complete muted set |
| `POST /api/project/<name>/boss` | `boss` | Create or update project |
| `POST /api/project/<name>/remove` | `{}` | Remove unused project |
| `POST /api/app` | `name`, `team`, `{repo,path,purpose,detail}` | Create application |
| `POST /api/app/<name>/set` | `field`, `value` | Update one application field |
| `POST /api/app/<name>/doc` | `text` | Replace plain-text manual |
| `POST /api/app/<name>/undo` | `snapshot` | Restore a history point |
| `POST /api/app/<name>/project` | `project`, `{role}` | Set application/project relation |
| `POST /api/app/<name>/unproject` | `project` | Remove one relation |
| `POST /api/app/<name>/remove` | `{}` | Remove application |

Exposed team fields are `prompt`, `speciality`, `parent`, `project`, `slave`,
`workdir`, `launch`, `session`, and `user`. `launch` is executed on the hub when
the managed session is created; the API does not make that value safe.

`members` is always a JSON array. For group removal, omitting it deletes the
whole group; sending an empty array is rejected rather than interpreted as
deletion.

## Files, backup, and fleet mutations

| Route | JSON body | Effect |
|---|---|---|
| `POST /api/upload` | `to`, `name`, `id`, `offset`, `{data,last,sha256}` | Append a verified upload chunk |
| `POST /api/shared/delete` | `dir`, `name`, `{recursive}` | Delete one anchored entry |
| `POST /api/backup` | `dir`, `{force}` | Create the built-in credential-bearing backup set |
| `POST /api/fleet/update` | `{team,force}` | Update one team host or the fleet to the published release |

For upload, `offset` starts at zero, `data` is base64, and the final chunk sets
`last:true` plus the SHA-256 digest of the complete file. The hub publishes only
after offset and digest verification.

For shared deletion, `dir` is one team directory or `.` for the exchange root;
`name` is one entry, never a path. `recursive:true` is explicit and destructive.

The built-in backup omits workflow undo snapshots and legacy manual files; see
[Operations](operations.md) for the separate retention requirement.

## Runtime help

`GET /api/help` is generated beside the route implementation and is consumed by
the browser to explain operations at the point of use. This document describes
the public contract; clients should still treat unknown fields and outcomes as
protocol drift rather than guessing.

For compatibility with the original browser contract, the help envelope keeps
the legacy keys `ayuda`, `ruta`, `que`, `pasa`, and `ojo`. Their values and all
text rendered by the English browser interface are English. New clients should
treat those names as fixed wire keys rather than localized labels.
