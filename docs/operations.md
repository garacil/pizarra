# Operations

pizarra is a single-hub system. Operate the hub's configuration, store, logs,
and SQLite databases as one security and recovery domain. Endpoint daemons may
be restarted independently; the hub journal will retry unacknowledged delivery.

## Deployment patterns

For an initial installation, keep the hub and web listener on loopback and run
local terminal sessions under one dedicated account. Add remote hosts with
reverse dial when the local setup is stable.

| Pattern | Inbound network paths | Credential on team host | Use case |
|---|---|---|---|
| Local sessions | Hub loopback only | None beyond local process access | Single control host |
| Reverse dial | Daemon to hub | Bound team credential | Preferred remote-host mode, NAT, changing addresses |
| Direct push | Hub to daemon | Hub master credential | Trusted, tightly controlled network only |
| Inbox only | Client to hub | Bound identity credential | No managed terminal session |

Use explicit IP addresses and host firewalls. The native bus, push port, and web
server are cleartext; secure transport is an independent deployment boundary.

## Canonical install layout

The installed suite uses one Unix layout:

```text
/usr/local/bin/pizarra
/usr/local/bin/tiza
/usr/local/bin/pzweb
/usr/local/share/pizarra/web/apps/
/etc/pizarra/pizarra.conf
/etc/pizarra/tiza.conf
/etc/pizarra/pzweb.conf
/etc/pizarra/agents/*.conf
/var/lib/pizarra/
/var/lib/pizarra/releases/
/var/log/pizarra/
```

`/etc/pizarra` holds only static/bootstrap process configuration and
identity-specific client files. Mutable state, all SQLite databases, and the
private endpoint-release root live in `/var/lib/pizarra`; logs live in
`/var/log/pizarra`. Teams, groups, projects, applications, manuals,
memberships, and application/project roles are not split into files under
`/etc`: they are authoritative rows in `org.sqlite`.

The configuration directory is mode `0711` so separately owned mode-`0600`
files can be opened by their exact service accounts without exposing a directory
listing. File ownership remains the actual access boundary. Keep production
configuration and state outside the source checkout.

```sh
./configure --prefix=/usr/local
make check
make test
sudo make install
sudo /usr/local/bin/tiza --config /etc/pizarra/tiza.conf --health
```

With no explicit `--config` or `PIZARRA_CONF`, a missing canonical
configuration triggers secure first-run initialization. It creates protected
config/state/log directories, a mode-`0700`
`/var/lib/pizarra/releases` root, matching mode-`0600` `pizarra.conf` and
`tiza.conf` files with a random shared credential, and an empty authoritative
SQLite registry. The generated hub config selects that canonical release root.
It never overwrites an existing file. Explicit and environment-selected paths
are strict and do not trigger this behavior.

First-run publication is resumable. A private mode-`0600` journal is protected
by a live advisory lock rather than by pathname existence. If the process dies
after publishing only one of the matching credential files, the next run
verifies that file against the journal and creates only its missing peer. A
stale unlocked journal cannot permanently block startup, and an unrelated
pre-existing identity is never adopted or overwritten.

`make install` accepts only the artifacts certified by `make test`, performs
the migration-only validation before starting anything, enables the tmux
boundary and hub units, and returns only after authenticated hub health passes.
Do not run a second `--migrate-only` against the now-running store.

The shipped services and migration defaults use `root:root`. That is deliberate
for the current deployment: the hub and daemon must control the already
root-owned tmux server and sessions. Changing only the unit user would make
those sessions invisible. A fresh installation may use dedicated `pizarra`,
`tiza`, and `pzweb` accounts, but change service `User`/`Group`, file ownership,
state/log ownership, and tmux-session ownership as one operation. Grant optional
shared-file access narrowly through a dedicated group or ACL.

## Consolidating an existing checkout-based installation

Use `scripts/migrate-to-system-layout.sh` to copy an existing deployment into
the canonical paths without deleting the source. The script selects or accepts
the exact source config, store, and release-artifact tree; captures each SQLite
database through the online backup API (including committed WAL data); verifies
integrity and table counts; and captures the complete release tree against a
stable manifest of entry names, entry types, and regular-file bytes. It also
copies ancillary Tiza and agent configs, preserves any legacy Telegram bridge
config, rewrites `[store] dir`, `[server] releases`, and `[log] path`, and
creates a rollback bundle under `/var/lib/pizarra-migration-backups/`.

Hub `[shared] dir` and pzweb `[web] shared` are preserved literally. The
migrator does not traverse, copy, move, or delete the configured shared/NFS
tree. The migrator refuses a relative value or any mismatch—including one side
empty and the other configured—before destination mutation. Before each dry run
and final cutover, also verify that the common absolute path resolves to the
intended mounted export and that every local `tiza share` consumer sees it at
the same path. Keep it external—`/mnt/pizarra-shared` is the portable
example—not below the canonical store.

The configured legacy `releases` value is consumed literally. If it is
relative, the script refuses to guess which historical process working
directory gave it meaning: supply its reviewed real absolute directory with
`--source-releases /absolute/legacy/release-root`. If a selected non-empty
release tree differs from a non-empty state-contained or canonical tree, the
migration aborts before installing anything; reconcile the trees explicitly.

It does **not** stop or restart a service and never touches a tmux session. A
live snapshot is safe, but writes made afterward require a final rerun while the
old hub is stopped. A conservative cutover is:

```sh
make check
make test

# Optional live preflight/snapshot; inspect every selected source printed.
sudo scripts/migrate-to-system-layout.sh --dry-run
sudo scripts/migrate-to-system-layout.sh

# Human-controlled quiescence: use the real old service/process name here. If
# the legacy hub lives in tmux, inspect and stop only that service session as
# described below; do not stop agent sessions.
sudo systemctl stop pizarra.service

# Capture final writes. Reuse explicit --source-config/--source-store options
# and --source-releases if the first run used them.
sudo scripts/migrate-to-system-layout.sh

# Import/verify legacy registry sections with the already verified checkout
# binary and exit before opening any listener.
sudo ./pizarra \
  --config /etc/pizarra/pizarra.conf --migrate-only

sudo sqlite3 -readonly \
  'file:/var/lib/pizarra/org.sqlite?mode=ro' \
  'PRAGMA integrity_check;'
sudo sqlite3 -readonly \
  'file:/var/lib/pizarra/org.sqlite?mode=ro' \
  "SELECT v FROM meta WHERE k='registry_authority';"

# The migration-only run may have removed legacy INI sections and upgraded
# SQLite. Record the now-canonical files as their own trusted lineage before
# retiring the old source paths.
sudo scripts/migrate-to-system-layout.sh \
  --source-config /etc/pizarra/pizarra.conf \
  --source-store /var/lib/pizarra \
  --source-releases /var/lib/pizarra/releases \
  --source-pzweb /etc/pizarra/pzweb.conf

# Record the EXACT remaining agent-session inventory. Adoption refuses a
# mismatch and never accepts a broad wildcard or implicit confirmation.
tmux list-sessions -F '#{session_name}'

# First manifest-backed cutover from the stopped legacy installation. Replace
# the example list with the exact reviewed comma-separated output above. With
# no remaining sessions, omit PIZARRA_ADOPT_TMUX_SESSIONS entirely.
sudo PIZARRA_ADOPT_TMUX_SESSIONS='agent-main,agent-review' make adopt

# `adopt` installs the verified payload and rendered units, snapshots the
# canonical state, preserves the reviewed tmux server, enables the hub and its
# tmux boundary, starts the hub, and commits its manifest only after strict
# authenticated health succeeds. A failure restores payload, state, and unit
# enablement/running state.
sudo systemctl --no-pager --full status pizarra-tmux.service pizarra.service
sudo /usr/local/bin/tiza --config /etc/pizarra/tiza.conf --health
sudo /usr/local/bin/tiza team list
sudo /usr/local/bin/tiza group list
sudo /usr/local/bin/tiza app list
```

The integrity result must be `ok` and the authority marker `sqlite-v1` before
starting the canonical service. `--migrate-only` verifies configuration,
schemas, credentials, legacy reconciliation, and the authoritative reload; it
starts neither the listener nor the watchdog. The first verified cutover keeps
an owner-only `pizarra.conf.pre-registry-sqlite.*.bak` and removes legacy
registry sections from the active bootstrap INI. A top-level `registry.ini` is
archived only as `legacy/registry.ini.pre-sqlite`; `apps.sqlite` is retained for
compatibility, not used as the live app registry.

The final explicit canonical-source pass is not a redundant copy. It refreshes
the root-owned migration lineage record after `--migrate-only` changes the INI
and database schemas, and makes future no-argument migration audits independent
of repository-local paths that retirement will remove.

The command block above cuts over to the shipped systemd service. For a
deployment still supervised by tmux, first inspect the exact sessions and start
commands:

```sh
tmux list-panes -a -F '#{session_name}\t#{pane_start_command}\t#{pane_current_command}'
```

Quiesce only the hub and web processes through their own clean shutdown
interfaces. Never destroy their tmux containers, and never stop, signal, rename,
or replace agent sessions such as `agent-main` or `agent-review`. After the
canonical migration, choose exactly one supervisor:

```sh
# Standard unattended deployment: the transactional installer enables systemd.
sudo PIZARRA_ADOPT_TMUX_SESSIONS='agent-main,agent-review' make adopt

# Visible-pane alternative (do not also start pizarra.service): Pizarra itself
# preserves an existing pane or creates the missing one exactly once.
sudo /usr/local/bin/pizarra --config /etc/pizarra/pizarra.conf \
  --host-session pizarra
```

The visible-pane command never replaces an existing session. Confirm the active
process uses only canonical paths before running the retirement script. The
exclusive store lock refuses an accidental second hub, but it is not a
substitute for inspecting which supervisor owns the production process.

Those commands use `root` because that is the shipped/current tmux deployment
default. If the migrator was run with `PIZARRA_OWNER=pizarra`, run
`--migrate-only` as that same account instead:

```sh
sudo -u pizarra /usr/local/bin/pizarra \
  --config /etc/pizarra/pizarra.conf --migrate-only
```

Do not run the hub constructor as root against a dedicated-user store: it may
need to create a schema file or workflow directory, and ownership would then be
wrong. The canonical database checks deliberately use normal read-only URI mode,
without `immutable=1`, so SQLite includes committed records that may still be in
the live WAL. Reserve `immutable=1` for a closed, immutable backup or completed
online-backup snapshot; using it on the canonical database can return stale
data by ignoring valid WAL state.

Migration ownership variables are:

| Variable | Default/behavior |
|---|---|
| `PIZARRA_OWNER`, `PIZARRA_GROUP` | `root:root`; own `pizarra.conf`, state, and logs and must match the hub/tmux owner |
| `PZWEB_OWNER`, `PZWEB_GROUP` | `root:root`; own `pzweb.conf` and should match the pzweb unit |
| `TIZA_OWNER`, `TIZA_GROUP` | unset preserves the resolvable source owner/group (otherwise falls back to root); override for Tiza and preserved legacy Telegram configs |
| `AGENTS_OWNER`, `AGENTS_GROUP` | unset preserves the resolvable source owner/group (otherwise falls back to root); override for `agents/*.conf` |

Use `sudo -E` only when intentionally passing these reviewed variables. The
migrator refuses ambiguous equal-age sources, unsafe symlinks, in-use canonical
state, unverified SQLite copies, conflicting non-empty release trees, and
non-empty destinations it cannot prove safe. It copies release artifacts
without deleting the selected source.

### Retiring the repository-local compatibility layout

Retire `.private/conf` and the temporary `conf/{pizarra.conf,pzweb.conf,store}`
layout only after the canonical hub and web console have passed the cutover
checks. The retirement command is a dry run unless `--confirm` is explicit:

```sh
sudo scripts/retire-repo-runtime-conf.sh
sudo scripts/retire-repo-runtime-conf.sh --confirm
```

The regression harness uses only a disposable tree below `/tmp`:

```sh
scripts/test-retire-repo-runtime-conf.sh
```

Retirement also requires the root-owned
`/var/lib/pizarra-migration-backups/installed-state.record` to name the
canonical configuration and state as its current source lineage. The explicit
canonical-source migrator pass above performs that repoint after
`--migrate-only`; do not skip it. This prevents retirement from leaving a
trusted record that names paths it is about to remove.

Repeat the shared-path equality and mount-reachability check immediately before
retirement. The retirement script does not archive or remove the external
shared/NFS tree; it removes only the verified repository-local compatibility
layout and eligible repository-local legacy log. The NFS lifecycle remains a
separate operator responsibility.

The command refuses to act unless both canonical configurations are private,
the hub points exactly at `/var/lib/pizarra`,
`/var/lib/pizarra/releases`, and `/var/log/pizarra`, and pzweb points at the
installed web assets. The release directory itself must be a real private
directory outside the repository, with no symlink or special-file entries. All
three databases must pass integrity and foreign-key checks, and `org.sqlite`
must have the `sqlite-v1` authority marker. Retirement also rejects open
handles, processes, or tmux launch commands that still use the old paths.

If shared exchange is configured, retirement additionally requires both
canonical values to be absolute and exactly equal, and proves that both literal
values match their corresponding repository-source configuration before
removing it. It deliberately does not stat or enumerate the external tree.

On confirmation, the complete old configuration/state tree is copied across
filesystems to a private, timestamped
`/var/lib/pizarra-migration-backups/retired-source-conf-*` archive. Complete tree
and file-content manifests are compared and synced before the source is removed.
A repository-local legacy log declared by the old configuration is included and
retired by the same verified operation; external log paths are never touched.
Only the three named compatibility symlinks are unlinked, then their empty
`conf` directory is removed. Any unexpected entry in that directory aborts the
operation before archival. Versioned examples under `examples/` and every other
repository file remain untouched. Repeating the command after a successful
retirement verifies and reuses the recorded archive.

## Supervision

Example service units are provided in `systemd/`. Review every path, user,
group, address, and capability before enabling them.

```sh
sudo install -m 0644 systemd/pizarra.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now pizarra.service
sudo systemctl status pizarra.service
```

The example services use `UMask=0077` and restart after failures. Run
`pizarra` or `tiza daemon` as the operating-system account that owns the
terminal sessions it manages. A hub that does not manage local sessions should
use a dedicated, unprivileged service account with access only to its config,
store, log, optional shared directory, and network sockets.

No supervisor operation ends a session. Every shipped unit that can hold a
tmux server in its control group (`pizarra.service`, `pizarra-tmux.service`,
`tiza.service`) carries `KillMode=process`, so `systemctl stop` or `restart` of
any of them signals only that unit's own main process. The hub and the daemon
have no command that kills, replaces, renames or relaunches a session, and no
configuration key enables one: a watchdog creates a session only when it is
absent, and an existing session always wins, whatever its launch command or
work directory say now. A hub that stops leaves every session open; a hub that
starts uses the sessions it finds. `scripts/test-no-destructive-tmux.sh` fails
the suite if such a path is ever added.

Start order is normally:

1. hub;
2. remote endpoint daemons;
3. web console;
4. human terminal consoles.

An endpoint may start first and reconnect, but the web server deliberately
fails startup if it cannot prove its hub identity and delegated capabilities.

## Health checks

Use protocol-aware checks rather than only checking for a listening port:

```sh
tiza ver
tiza fleet
tiza team list
tiza task list open
tiza wf list
```

`tiza ver` compares the local suite and hub. `tiza fleet` reports local, push,
and dial hosts, observed endpoint versions, connection state, hosted teams, and
reported activity where enabled.

Operational warning signs include:

- a persistent version mismatch;
- a dial team remaining offline;
- queued messages that do not drain after an endpoint returns;
- a team that never receives anything while `tiza fleet` reports its host
  `ONLINE`, which usually means the endpoint has no `[session:TEAM]` block for
  it: the daemon refuses each delivery, the hub records it as an ordinary
  queueing event, and only the delivery high-water mark stuck at zero shows it;
- repeated structural `gap` events for live observers;
- an active workflow step with no linked task;
- repeated stalled-step or blocked-activity alarms;
- SQLite/schema/registry load preventing hub startup;
- a web server that stops at its startup capability check.

Inspect the hub log and current durable state before retrying any mutation whose
outcome was reported as unknown.

## Persistent state

The store may contain:

```text
.pizarra-hub.lock    persistent inode used for the exclusive hub/restore lock
messages.jsonl        durable message journal
state.json            delivery and inbox high-water marks
tareas.json           task store
workflows.json        workflow store and durable notification outbox
wfhistory/             workflow mutation snapshots
appdocs/               compatibility/manual state where present
org.sqlite             authoritative organization/apps/manuals/relations
work.sqlite            task projection and history
apps.sqlite            legacy compatibility/migration database
backups/               default backup destination
releases/              canonical private endpoint-release artifacts
```

The exact set depends on features used and migrations performed. JSON stores
use write-to-temporary-file plus atomic rename. Message append is flushed before
delivery. `org.sqlite` is mandatory authority: if the SQLite library, schema, or
complete registry projection is unavailable, the hub refuses to start rather
than running with an incomplete organization.

Never edit live store files manually. Registry mutations are DB-first and do
not rewrite registry sections into the hub INI. Back up the bootstrap
configuration and store together because both are required for a coherent
identity and recovery domain.

`.pizarra-hub.lock` is deliberately persistent. It is not a PID file and its
mere presence does not mean the hub is running; ownership of the advisory lock
is held by an open descriptor. Do not remove or replace the inode as routine
cleanup. Use the process/service state plus a non-blocking lock attempt when
establishing quiescence.

## Backups

Create a hot, internally consistent backup through the hub:

```sh
tiza backup /srv/secure-backups/pizarra
tiza backup verify /srv/secure-backups/pizarra/pizarra-<timestamp>
```

With no destination, the hub writes below `<store>/backups`. An explicitly
selected destination inside a Git worktree is rejected unless `--force` is
given. Do not use `--force` as routine policy.

The backup operation:

- uses the SQLite online-backup API for all three databases;
- holds one ordered snapshot barrier across configuration, workflows, tasks,
  messages, and SQLite so the pieces describe one consistent point in time;
- copies `pizarra.conf` and, when present, exactly `messages.jsonl`,
  `state.json`, `tareas.json`, and `workflows.json`;
- writes sizes and SHA-256 digests to `MANIFEST`;
- assembles in a temporary directory and renames it only when complete; and
- protects the finished directory with owner-only permissions.

The artifact includes credentials. Treat it as a credential bundle: encrypt it
at rest, restrict access, keep it outside the repository and shared exchange,
and test recovery on an isolated host.

The built-in backup does **not** include the `wfhistory/` workflow undo
snapshots, legacy `appdocs/` files, `/var/lib/pizarra/releases/`, or any content
below the configured external `[shared] dir`. Current
application manuals are retained in the SQLite registry after migration, but
old migration material may still matter to a particular installation. Release
artifacts can normally be regenerated from the exact committed source. The
backup does include `pizarra.conf`, so its shared-path reference is present,
but not one byte of the NFS tree. Back up any required excluded tree separately,
using a coordinated NFS/filesystem snapshot or copying while writers are
quiescent; protect and verify it like the main backup. `tiza restore` does not
restore these excluded directories.

`tiza backup verify` is local and non-mutating. It checks manifest hashes, parses
the saved configuration with the hub's actual loader, runs SQLite integrity and
foreign-key checks on all three databases, requires the registry-authority
marker, and rejects every physical payload file not declared by the closed
allow-list. A periodic isolated restore remains the strongest end-to-end test.
Separately retained historical directories are outside this artifact and need
their own verification.

## Restore

Restore is a local operation on the hub host and replaces live state. First
identify the exact hub configuration and stop that hub:

```sh
sudo systemctl stop pizarra.service
sudo env PIZARRA_CONF=/etc/pizarra/pizarra.conf \
  /usr/local/bin/tiza restore \
  /srv/secure-backups/pizarra/pizarra-<timestamp> --dry-run
```

Review the printed configuration path, store path, backup path, and credential
warning. Then perform the explicit restore:

```sh
sudo env PIZARRA_CONF=/etc/pizarra/pizarra.conf \
  /usr/local/bin/tiza restore \
  /srv/secure-backups/pizarra/pizarra-<timestamp> --confirm
```

The restore command must acquire `/var/lib/pizarra/.pizarra-hub.lock` with the
same exclusive lifetime lock as the hub, and also refuses while the configured
hub port answers. This closes the startup window where SQLite is open before the
listener exists. If the lock metadata is absent, run the new hub once with
`--migrate-only` before attempting restore. Restore verifies the backup before
changing state, snapshots the complete list of current root files, and moves
them into a timestamped `.pre-restore-*` safety directory. It then proves no
root file remains before copying the allow-listed payload, so a stale SQLite WAL
or shared-memory file cannot replay newer data over the restored databases.
When restore is run through `sudo` for a hub owned by a dedicated account, it
preserves the existing store and configuration owners on replacement files
rather than leaving unreadable root-owned mode-`0600` state.

If the saved and current bus credentials differ—or cannot be compared—the
command stops before moving files. `--force` is a separate acceptance of that
fleet-wide credential consequence. After restore:

1. start the hub;
2. check teams and application registries;
3. inspect tasks, workflows, and recent messages;
4. confirm remote delivery and web startup;
5. retain the `.pre-restore-*` directory until validation is complete.

Restoring `pizarra.conf` can restore its `[shared] dir` reference, but it never
changes the external shared/NFS data. Verify that the restored hub reference
and pzweb `[web] shared` are still exactly equal and point at the intended
mount. Restore shared content, when required, from its separately coordinated
snapshot rather than through `tiza restore`.

## Fleet releases and updates

The update channel serves an endpoint binary for a matching OS/CPU and a source
archive fallback. It never accepts an arbitrary download URL from the caller.

Prepare a release from a clean, committed tree:

```sh
make test
make publish
```

Run `make publish` as the account that owns the private canonical release root.
`RELEASEDIR` defaults to `/var/lib/pizarra/releases`; an override must also be
an absolute path. The target is mode `0700`, may not be a symbolic link, and
must match `[server] releases` exactly. That setting is used literally, so never
configure a relative release path.

The target contains `tiza-<os>-<cpu>`, `src.tar.gz`, and `VERSION`. Publication
stages each artifact under a temporary name, atomically renames the binary and
source archive, and renames `VERSION` last. The hub reads those exact names and
offers an update only when `VERSION` exactly matches the running hub version;
this prevents advertising stale or half-written artifacts.

Inspect the fleet, then trigger one host before broad rollout:

```sh
tiza fleet
tiza update reviewer
tiza fleet
tiza update all
```

Endpoint downloads are chunked and verified against the advertised whole-file
SHA-256 digest. Installation stages an atomic replacement and first creates a
rollback copy. A failed post-install version check restores that copy; a
verified success removes rollback copies. The endpoint update artifact is
capped at 128 MiB.

`autoupdate = on` lets a daemon act on a newer published version reported by the
hub. Keep it off when change control requires an operator-triggered rollout.
An offline dial host catches up after reconnection only when automatic update is
enabled or an operator triggers the update again.

Local teams use the control host's installed binary; update them through the
normal build/install process, not the endpoint trigger.

## Credential rotation

Plan rotations because identity credentials are distributed state:

1. take and verify a backup;
2. inventory every identity and delivery mode;
3. update one unique team credential in both the hub and its client/daemon
   configuration;
4. restart or reconnect that endpoint and verify messaging;
5. repeat per team;
6. rotate the web identity and restart `pzweb` so startup revalidates it;
7. rotate the master credential last and restart direct-push daemons that
   currently depend on it;
8. create a new backup and retire old credential-bearing artifacts.

Do not temporarily reuse a master credential as a team credential. The hub
rejects that configuration, and it erases the boundary the rotation is meant to
restore.

## Routine maintenance

- Verify backups on creation and perform periodic isolated restores.
- Watch free space for the journal, snapshots, databases, logs, and backups.
- Keep only the release artifacts meant to be served.
- Review delegated command families and group/project administrators.
- Review teams with executable `launch` values and the accounts that run them.
- Confirm daemon receipt-state paths remain writable and durable.
- Investigate live-feed `gap` events rather than treating them as cosmetic.
- Compare versions after every release.
- Review completed, aborted, and halted workflows as durable operational
  records before applying retention policy.

See [Security](security.md) for trust boundaries and [Testing](testing.md) for a
release validation matrix.
