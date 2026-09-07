# Configuration reference

Static process settings use INI files; the organization registry does not.
Public examples live in `examples/`, while the canonical installed configuration
is under `/etc/pizarra/`. Real files contain credentials and must never be placed
under the repository.

The canonical layout is:

| Path | Purpose |
|---|---|
| `/etc/pizarra/pizarra.conf` | Hub bootstrap, network, log, store, prompt, and delivery-header settings |
| `/etc/pizarra/tiza.conf` | Console/CLI identity and optional local host-daemon settings |
| `/etc/pizarra/pzweb.conf` | Web adapter, hub identity, HTTP perimeter, and asset settings |
| `/etc/pizarra/agents/*.conf` | Optional identity-specific client files used by managed agent sessions |
| `/var/lib/pizarra/` | SQLite databases, message/task/workflow state, receipts, backups, and endpoint release artifacts |
| `/var/lib/pizarra/releases/` | Canonical private release root used by the endpoint update channel |
| `/var/log/pizarra/` | Hub logs |
| `/usr/local/share/pizarra/web/apps/` | Installed browser assets loaded by `pzweb` |

Teams, groups, projects, applications, application manuals, memberships, and
application/project relations are authoritative in
`/var/lib/pizarra/org.sqlite`. They are managed through the authenticated hub
commands, not by creating one INI file or section per object.

## Resolution and identity

Each program accepts an explicit path, but its only implicit runtime location is
`/etc/pizarra`:

```sh
pizarra --config /etc/pizarra/pizarra.conf
tiza --config /etc/pizarra/tiza.conf <command>
tiza daemon --config /etc/pizarra/tiza.conf
pzweb --config /etc/pizarra/pzweb.conf
```

`PIZARRA_CONF`, `TIZA_CONF`, and `PZWEB_CONF` override the corresponding
implicit file. For `pizarra` and `pzweb`, resolution order is explicit
`--config`, environment override, then `/etc/pizarra/<name>`. `tiza` uses the
same order, with one identity-preserving step before the canonical default: when
it is running inside a tmux session tagged by `tiza daemon`, it reads that
session's `@pizarra_conf` option. This lets a bare `tiza` keep the session's
identity even if a child process did not inherit `TIZA_CONF`.

An explicit, environment-selected, or tmux-tagged path that is missing fails
closed: the program never falls back to another identity, the home directory,
the source tree, or the current directory. The host daemon derives the tag from
the reviewed `TIZA_CONF=...` assignment in that session's `launch` command; the
tag does not copy a credential into tmux, only the path to its protected
identity file.

When `pizarra` is started with no explicit path and no `PIZARRA_CONF`, a missing
canonical hub file is treated as a first installation. With sufficient
privileges it creates private `/etc/pizarra`, `/var/lib/pizarra`,
`/var/lib/pizarra/releases`, and `/var/log/pizarra` structure plus matching
`pizarra.conf` and `tiza.conf` credentials. The generated hub file points
`[server] releases` at that canonical artifact root. Existing files are never
overwritten. Explicit and environment paths never trigger this bootstrap.
Publication of the two credential files is crash-resumable: a private
mode-`0600` journal holds the generated secret under an exclusive live lock.
After an interruption, the next run verifies any already-published peer and
creates only the missing file. Pathname existence alone is never treated as a
lock, so a dead initializer cannot permanently block startup.

Every selected credential-bearing INI is opened once through a descriptor that
is kept for the complete parse. The final file must be a regular mode-`0600`
file owned by the runtime uid, and group/other-writable ancestors are rejected
except for a root-owned sticky directory such as `/tmp`. Parsing remains pinned
to the opened inode if its pathname is replaced, and quoted values have the same
stripping semantics in every typed loader.

Ancestor symbolic links are resolved before those rules are applied, and every
requirement is then enforced on the resolved location. A link is followed only
when it is owned by `root` or by the runtime uid; one owned by anybody else is
refused by name, as is a chain deeper than 32 links. **The final component is
never followed**: a credential that is itself a symbolic link is refused.

This matters on any platform whose own layout is built from links. On macOS
`/etc` and `/var` are symbolic links into `/private`, so a literal
"no symbolic link in any path component" rule made every canonical path
illegal there and an endpoint could only start with a hand-written `--config`.
Resolving first keeps the protection — redirecting a resolved path still
requires write access to a directory the ancestor rules already refuse — while
allowing the platform's own layout.

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
| `attach_local` | `off` | Allow `tiza attach` into the hub host's OWN local team sessions |
| `attach_trust` | empty | Identities that may attach AND write ANY team: a comma/space list, or `all`. Empty keeps write to `console` only |
| `shell_local` | `off` | Allow `tiza shell` to open a login shell on the hub host's OWN machine |
| `shell_user` | empty | Ordinary account that shell opens as on the hub host. Never `root`; empty means no shell here whatever `shell_local` says |
| `shell_trust` | empty | Identities that may open a shell on ANY host: a comma/space list, or `all`. Empty keeps it to `console` only. Its own key, never `attach_trust` |
| `header` | `short` | Delivery envelope mode: `short` or `full` |
| `releases` | empty | Literal directory containing published endpoint update artifacts; empty disables updates |
| `alarm_max` | `3` | Block alarms per episode, clamped to 1–5 |
| `alarm_every` | `180` | Seconds between alarms, minimum 15 |
| `group_idle_dwell` | `120` | Seconds a group must remain idle before its idle action, minimum 15 |

Set `master_console_only = on` only after every team and daemon uses an
appropriate bound credential. Enabling it earlier can reject legitimate team
traffic that still uses the master secret.

For an enabled canonical deployment, set `releases` to the exact absolute path
`/var/lib/pizarra/releases`. Keep that directory real (not a symlink), private
at mode `0700`, and owned by the hub account. The loader uses the value
literally: a relative value depends on the process working directory and is
therefore not a safe production configuration. The hub reads only `VERSION`,
`src.tar.gz`, and `tiza-<os>-<cpu>` from this root; the published `VERSION` must
exactly match the running hub version before any artifact is advertised.

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

### `[registry]`

```ini
[registry]
authority = sqlite
```

`sqlite` is the only supported live authority. If SQLite cannot be loaded, its
schema cannot be upgraded, or `org.sqlite` cannot be projected completely, the
hub refuses to start. It does not continue from an incomplete INI registry.

On the first cutover of a legacy installation, old `[team:*]`, `[group:*]`,
`[project:*]`, and `[app:*]` sections are migration input only. The hub:

1. takes a mandatory online SQLite backup when a pre-existing store is present;
2. reconciles legacy and database rows without deleting database-only data;
3. imports manuals and the union of application/project relations;
4. reloads and verifies the complete typed registry;
5. writes a private `pizarra.conf.pre-registry-sqlite.*.bak` copy;
6. removes the legacy registry sections from `pizarra.conf`; and
7. writes the `registry_authority=sqlite-v1` database marker last.

An interrupted import therefore retries without declaring partial state
authoritative. After that marker exists, the INI is never a second registry.

### `[log]`, `[store]`, `[shared]`, and `[prompts]`

```ini
[log]
path = /var/log/pizarra/pizarra.log

[store]
dir = /var/lib/pizarra

[shared]
dir = /mnt/pizarra-shared

[prompts]
global = Short project context included in deliveries.
; global_file = prompts/project.txt
```

- `store.dir` defaults to `/var/lib/pizarra`. The directory must be private,
  writable by the hub account, and backed up as a unit.
- `shared.dir` is optional and may be a separately mounted NFS tree. A non-empty
  value must be absolute; the hub refuses a relative path rather than resolving
  it against its process working directory. It is not part of the hub store and
  must not be moved below `/var/lib/pizarra`. The hub creates one flat directory
  per team plus `console`, with a startup guide at the root. Never place secrets,
  live configuration, or backup bundles there.
- `global_file` is resolved relative to the configuration directory unless
  absolute, and takes precedence over `global`.

## SQLite organization registry

The following are logical records in `org.sqlite`, exposed through `tiza`, the
terminal console, the native protocol, and `pzweb`. The legacy INI headings are
shown nowhere in a current configuration because there is no duplicated live
INI registry.

### Teams

Each team has a stable numeric ID and an addressable name.

| Key | Meaning |
|---|---|
| `name` | Required addressable name |
| `speciality` | Short routing description |
| `prompt` | Team-specific delivery instruction |
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

### Groups

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

Use `tiza group onblock <name> alarm|log|default` to change `on_block` through
the authoritative hub. `default` stores no group override and therefore uses
the normal alarm behavior. `log` suppresses the loud operator alarm for a
detected block in that group; it does not disable detection, delivery holds, or
an explicitly configured `auto_enter` action.

Policy composition is deliberately conservative about noise suppression: a
team is log-only when it is a non-excluded member of at least one group whose
policy is `log`. An `alarm` policy in another group does not override that
match. Excluding the team from the log-only group removes that group's effect.

### Projects

A project stores its name and administrator. Teams and groups may carry project
labels, while registered applications may have explicit many-to-many project
relations with a role per relation.

### Applications, manuals, and relations

| Key | Meaning |
|---|---|
| `team` | One responsible team, or `-` for unassigned |
| `repo` | Repository URL or path |
| `path` | Runtime/source location |
| `purpose` | One-line purpose |
| `detail` | Longer description |
| project relations | Zero or more project assignments, each with a pair-specific role |

Application rows, manual bodies, project assignments, pair-specific roles, and
their audit history all live in `org.sqlite`. `apps.sqlite` is retained as a
legacy compatibility/migration database; it is not the current application
authority. Foreign-key cascades in `org.sqlite` remove relation rows when an app
or project is deleted without deleting the surviving object.

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
| `listen` | `127.0.0.1` | Push listener; override with an explicit private address |
| `port` | `7011` | Push delivery port |
| `secret` | `[pizarra] secret` | Credential expected from the hub; push mode currently receives the hub master secret |
| `dial` | `off` | Open a reverse channel to the hub |
| `keepalive` | `60` | Reverse-channel keepalive seconds, minimum 5 |
| `state` | `/var/lib/pizarra/tiza.state` | Writable deduplication receipt path |
| `autoupdate` | `off` | Automatically install a newer published endpoint |
| `attach` | `off` | Host-wide default for `[session:] attach`; one key opts every session on this host into `tiza attach` |
| `shell` | `off` | Allow `tiza shell` to open a login shell on THIS host. Host-wide: a shell belongs to the machine, so there is deliberately no `[session:] shell` key |
| `shell_user` | empty | Ordinary account the shell opens as. Never `root` - the operator escalates with `sudo su` inside. With `shell = on` and this empty the daemon refuses |
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
| `attach` | Allow `tiza attach` into this pane; off by default |

`auto_enter` accepts the terminal's highlighted default. Enable it only for a
trusted session where that behavior is explicitly intended.

`attach` opts this pane into `tiza attach`, the operator's own decision per
session, exactly as `activity` opts into sampling. It is off by default; the hub
cannot override it. Write access additionally requires the console credential.

Every team whose delivery route is this daemon needs a block here. A team the hub
knows with a `host` pointing at this machine but with no matching
`[session:TEAM]` is refused at the application level: the daemon replies
`session not declared: TEAM`, the hub reads only the `ok` field of that reply and
records an ordinary queueing event, and the messages accumulate in order for as
long as the omission lasts. The transport succeeded, so no push failure is
logged; the hub log shows only `queued seq=N for TEAM`, which is what an offline
host looks like too. Meanwhile `tiza fleet` keeps reporting the host `ONLINE`,
because reachability is a property of the daemon, not of the missing block. The
distinguishing symptom is a delivery high-water mark that never leaves zero.
Prove a newly registered team with one real message rather than assuming that
registering it on the hub completed the deployment.

`launch` runs with the environment of the tmux server, which is not a login
session. When the daemon is the first thing on the host to touch tmux it forks
that server itself, and a pane created afterwards inherits an empty `HOME`. A
`bash -lc` login shell then expands `$HOME` to nothing while building `PATH`, so
a bare command name installed under a home directory is not found and the
session exits at once; the watchdog reports `session disappeared immediately;
the launch command exited` on every pass. For an agent installed below a home
directory, the difference is the whole failure:

```text
HOME unset           -> PATH=/.local/bin:...               -> command not found
HOME=/home/builder   -> PATH=/home/builder/.local/bin:...  -> found
```

Give `launch` an absolute binary path and set `HOME` explicitly. On a host that
carries more than one team, also export that team's own credential: it is what
the daemon reads back to tag the session with `@pizarra_conf`, so a bare `tiza`
in that pane keeps the intended identity instead of inheriting the file-level
`[pizarra] self` of the host.

```ini
launch = bash -lc 'export HOME=/home/builder; export TIZA_CONF=/etc/pizarra/agents/builder.conf; exec /home/builder/.local/bin/start-ai-agent'
```

Point `launch` at a stable symbolic link rather than a versioned binary, so the
agent's own self-update cannot invalidate the line. An empty `launch`
deliberately describes a manually managed session: it is delivered to and tagged
while it exists, and is never recreated when it is absent.

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
| `static` | `/usr/local/share/pizarra/web/apps` | Installed frontend directory |
| `shared` | empty | Optional absolute shared-file root used by browser file views |
| `user` | none | Required HTTP Basic username; no colon |
| `password_sha256` | none | Required lowercase 64-hex SHA-256 password digest |

The static and optional shared paths must exist at startup and contain no
symlink in any path component. A configured shared path must be absolute;
`pzweb` rejects a relative value instead of making it depend on its working
directory. `origin` must exactly describe the cleartext HTTP authority in
`host`; the current server does not implement proxy-aware origin rewriting.

When the exchange is enabled, hub `[shared] dir` and pzweb `[web] shared` must
name the same reviewed absolute mount, for example `/mnt/pizarra-shared`.
Clients using `tiza share` also need that mount visible at the same path; clients
without it use `tiza put` and `tiza get` through the bus. Migration preserves
both configuration values literally and does not copy the external tree. The
built-in backup includes the hub configuration reference but no shared-file
content; restore may restore that reference and never restores the NFS data.

## Runtime edits

Team, group, project, application, manual, and relation mutations commit to
SQLite before the new in-memory projection is published. A failed database
write is reported and does not become transient configuration that disappears
on restart. Header settings remain bootstrap INI values; tasks and workflows
retain their documented stores and SQLite projections.

Use `tiza team`, `tiza group`, `tiza project`, and `tiza app` (or the equivalent
console/web operations) for registry changes. Do not add live registry sections
to `pizarra.conf` and do not edit `org.sqlite` behind a running hub.
