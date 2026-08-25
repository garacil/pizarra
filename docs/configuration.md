# Configuration reference

The suite uses INI files. Public examples live in `conf/`; real configuration
contains secrets and must remain untracked.

## Resolution and identity

`pizarra` resolves `pizarra.conf`; `tiza` resolves `tiza.conf`. Prefer an
explicit path in services and automation:

```sh
pizarra --config /etc/pizarra/pizarra.conf
tiza --config /etc/tiza/tiza.conf <command>
tiza daemon --config /etc/tiza/tiza.conf
pzweb --config /etc/pzweb/pzweb.conf
```

The native programs also honor `PIZARRA_CONF` and `TIZA_CONF`, then look in the
user configuration directory, `/etc/pizarra`, and the current directory.
Explicitly requested paths fail closed when missing; they do not silently fall
back to another identity.

For `tiza`, `[pizarra] self` is the identity. A normal `--from` argument is
ignored. Use one configuration per identity, especially on a multi-team host.

## Hub: `pizarra.conf`

### `[server]`

| Key | Default | Meaning |
|---|---:|---|
| `listen` | `127.0.0.1` | Exact address on which the hub accepts connections |
| `port` | `7010` | Native bus TCP port |
| `secret` | empty | Master credential; must be set |
| `master_console_only` | `off` | Restrict the master credential to `from=console` |
| `header` | `short` | Delivery envelope mode: `short` or `full` |
| `releases` | empty | Directory containing published endpoint update artifacts |
| `alarm_max` | `3` | Block alarms per episode, clamped to 1–5 |
| `alarm_every` | `180` | Seconds between alarms, minimum 15 |
| `group_idle_dwell` | `120` | Seconds a group must remain idle before its idle action, minimum 15 |

Set `master_console_only = on` only after every team and daemon uses an
appropriate bound credential. Enabling it earlier can reject legitimate team
traffic that still uses the master secret.

### `[header]`

These keys tune the compact delivery envelope:

| Key | Default | Values |
|---|---:|---|
| `style` | `on` | Include the receiving team's style prompt |
| `orders` | `on` | Include the wait-for-orders rule where applicable |
| `tasks` | `on` | Include an actionable-task pointer/count |
| `teams` | `on` | Include the team-directory command pointer |
| `group` | `own` | `own` or `off` |
| `project` | `off` | Include global project prompt/context |
| `subs` | `off` | Include subordinate/delegation details |
| `shared` | `on` | Include shared-file paths and instructions |
| `workflow` | `on` | Include active workflow responsibilities |
| `manual` | `first` | `first`, `always`, or `off` |
| `note` | empty | Standing instruction shown to every team |

Boolean values accept `on/off`, `1/0`, `true/false`, and `yes/no`.

### `[log]`, `[store]`, `[shared]`, and `[prompts]`

```ini
[log]
path = /var/log/pizarra/pizarra.log

[store]
dir = /var/lib/pizarra

[shared]
dir = /srv/pizarra/shared

[prompts]
global = Short project context included in deliveries.
# global_file = prompts/project.txt
```

- `store.dir` defaults beside the hub configuration. It must be writable and
  backed up as a unit.
- `shared.dir` is optional. The hub creates one flat directory per team plus
  `console`, with a startup guide at the root.
- `global_file` is resolved relative to the configuration directory unless
  absolute, and takes precedence over `global`.

### `[team:N]`

`N` is the stable numeric team ID.

| Key | Meaning |
|---|---|
| `name` | Required addressable name |
| `speciality` | Short routing description |
| `prompt` / `prompt_file` | Team-specific delivery instruction; file wins |
| `parent` | Parent team in the hierarchy |
| `project` | Direct project label |
| `secret` | Unique credential bound to this team |
| `delegate` | Comma-separated administrative families |
| `host` | Remote push address, optionally with port |
| `dial` | Use the daemon's reverse connection instead of push |
| `tmux_session` | Local terminal session; `-` means inbox only |
| `launch` | Command used to create a missing local session |
| `workdir` | Session working directory |
| `user` | Operating-system account used for the local session |
| `slave` | Mark the team read-only and restricted to its parent |
| `hold_when_blocked` | Hold deliveries when a reliable blocked state is reported |

Valid object names begin with an alphanumeric character and otherwise use only
letters, digits, `.`, `_`, or `-`. Parent links are validated for missing teams
and cycles.

Delivery selection:

- `dial = on`: reverse-dial delivery;
- otherwise `host` set: remote push delivery;
- otherwise `tmux_session` set: local terminal delivery;
- otherwise: inbox-only delivery.

`launch` is executable code. `user` is validated as an account-like name, but
that does not make the launch command safe. Run the hub with the least privilege
that can access the intended terminal sessions.

Administrative families are:

```text
team group project app task workflow watch backup update header
```

`watch` grants visibility into all bus traffic. `backup` can write copies that
contain secrets. `update` restarts endpoint daemons. `header` changes context
shown to the fleet. Delegate each deliberately.

### `[group:NAME]`

| Key | Meaning |
|---|---|
| `members` | Comma/space-separated team names |
| `excluded` | Members skipped only by `@group` fan-out |
| `boss` | Group administrator and escalation target |
| `project` | Project label inherited by members/workflows |
| `header` | Standing instruction for every member delivery |
| `on_idle` | `off`, `boss`, `all`, or a comma-separated recipient list |
| `on_idle_msg` | Message sent when the group remains fully idle |
| `on_idle_from` | Sender identity used for that message |
| `on_idle_reply` | Reply destination advertised to recipients |
| `on_block` | `alarm` or `log` behavior for detected permission blocks |

Excluded teams remain group members for organization, authority, project, and
workflow purposes; they are only muted from group broadcasts.

### `[project:NAME]`

```ini
[project:release]
boss = planner
```

A project currently stores its name and administrator. Teams and groups may
carry project labels, while registered applications may have explicit
many-to-many project relations with a role per relation.

### `[app:NAME]`

| Key | Meaning |
|---|---|
| `team` | One responsible team, or `-` for unassigned |
| `repo` | Repository URL or path |
| `path` | Runtime/source location |
| `purpose` | One-line purpose |
| `detail` | Longer description |
| `projects` | Mirrored project relation list maintained by runtime operations |

Application manuals and relation roles are stored in hub state rather than
inline in the INI.

## Endpoint: `tiza.conf`

### `[pizarra]`

| Key | Default | Meaning |
|---|---:|---|
| `host` | `127.0.0.1` | Hub address |
| `port` | `7010` | Hub port |
| `secret` | empty | Credential presented to the hub |
| `self` | empty | Required identity for network operations |

### `[daemon]`

| Key | Default | Meaning |
|---|---:|---|
| `listen` | `0.0.0.0` | Push listener; override with an explicit private address |
| `port` | `7011` | Push delivery port |
| `secret` | `[pizarra] secret` | Credential expected from the hub; push mode currently receives the hub master secret |
| `dial` | `off` | Open a reverse channel to the hub |
| `keepalive` | `60` | Reverse-channel keepalive seconds, minimum 5 |
| `state` | `<config>.state` | Writable deduplication receipt path |
| `autoupdate` | `off` | Automatically install a newer published endpoint |
| `update_path` | `/usr/local/bin/tiza` | Installed endpoint binary |
| `update_sudo` | `off` | Use privilege elevation for installation |
| `update_fpc` | `fpc` | Compiler used by source-fallback updates |

The directory containing `state` must be writable by the daemon. Without a
durable receipt, a daemon restart can cause an already injected delivery to be
injected again.

In push mode, the hub currently signs `deliver` with its master secret, so the
remote `[daemon] secret` must match it. Reverse dial authenticates the daemon to
the hub with its bound team credential and is preferable when the master secret
must remain only on the control host.

### `[session:TEAM]`

| Key | Meaning |
|---|---|
| `tmux_session` | Required delivery target; defaults to `team-TEAM` |
| `launch` | Command used to start a missing session |
| `workdir` | Session working directory |
| `user` | Operating-system account used for the session |
| `activity` | Enable pane activity sampling |
| `idle_match` | Extra `|`-separated idle markers |
| `block_match` | Extra `|`-separated blocked markers |
| `hint` | Optional file whose content overrides heuristic activity state |
| `auto_enter` | Automatically press Enter on a detected block; off by default |

`auto_enter` accepts the terminal's highlighted default. Enable it only for a
trusted session where that behavior is explicitly intended.

## Web: `pzweb.conf`

The file must be a regular file with no symlink in its path and permissions
exactly `0600`.

### `[pizarra]`

`host`, `port`, `secret`, and `self` select the bound team credential used by
the web server. Startup proves the credential cannot speak as `console` and
requires all ten delegated command families.

### `[web]`

| Key | Default | Meaning |
|---|---:|---|
| `listen` | `127.0.0.1` | Exact non-wildcard IPv4 listener |
| `port` | `7080` | HTTP port |
| `allow_from` | none | Required IPv4/CIDR admission list |
| `host` | none | Required exact HTTP `Host` authority |
| `origin` | none | Required exact mutation origin, `http://` plus `host` |
| `static` | `web/apps` | Bundled frontend directory |
| `shared` | empty | Optional shared-file root used by browser file views |
| `user` | none | Required HTTP Basic username; no colon |
| `password_sha256` | none | Required lowercase 64-hex SHA-256 password digest |

The static and optional shared paths must exist at startup and contain no
symlink in any path component. `origin` must exactly describe the cleartext HTTP
authority in `host`; the current server does not implement proxy-aware origin
rewriting.

## Runtime edits

Team, group, project, application, header, task, and workflow commands can
persist changes. The first runtime organization write preserves a backup of the
original INI because subsequent machine writes do not retain comments. Keep the
declarative file and the whole store directory in the same backup policy.
