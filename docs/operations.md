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

## Install layout

The default `make install` layout is:

```text
/usr/local/bin/pizarra
/usr/local/bin/tiza
/usr/local/bin/pzweb
/usr/local/share/pizarra/web/apps/
```

The hub example uses `/etc/pizarra/`, while its mutable state normally lives
below `/var/lib/pizarra/`. The endpoint daemon and web console use separate
`/etc/tiza/` and `/etc/pzweb/` directories so their service accounts cannot
read the hub master configuration. These are examples, not mandatory paths.
Choose absolute paths and keep production configuration outside the source
checkout.

```sh
./configure --prefix=/usr/local
make check
make
sudo make install
# Create the dedicated system account first with your operating system's tools.
sudo useradd --system --home-dir /var/lib/pizarra --shell /usr/sbin/nologin pizarra
sudo install -d -m 0700 -o pizarra -g pizarra \
  /etc/pizarra /var/lib/pizarra /var/log/pizarra
sudo install -m 0600 -o pizarra -g pizarra conf/pizarra.conf.example \
  /etc/pizarra/pizarra.conf
```

If the account already exists, skip `useradd`. Distribution-specific account
creation commands vary. The log directory is required by the example
`[log] path`; without a writable parent, file logging cannot succeed.

On a web host, create a separate `pzweb` system account and an owner-only
`/etc/pzweb/` directory, then install `pzweb.conf` there as that account with
mode `0600`. On an endpoint host, do the same with a `tiza` account and
`/etc/tiza/tiza.conf`, plus an owner-only `/var/lib/tiza/` state directory;
that account must own its configured tmux sessions and receipt state. If
components share a host, never give `pzweb` or `tiza` access to
`/etc/pizarra/`, the hub store, or the hub user's tmux server. Grant optional
shared-file access narrowly through a dedicated group or ACL.

Install endpoint and web configuration separately only on hosts that need
them. Replace every placeholder secret before starting a service.

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
- repeated structural `gap` events for live observers;
- an active workflow step with no linked task;
- repeated stalled-step or blocked-activity alarms;
- SQLite entering read-only degradation;
- a web server that stops at its startup capability check.

Inspect the hub log and current durable state before retrying any mutation whose
outcome was reported as unknown.

## Persistent state

The store may contain:

```text
messages.jsonl        durable message journal
state.json            delivery and inbox high-water marks
tareas.json           task store
workflows.json        workflow store and durable notification outbox
wfhistory/             workflow mutation snapshots
appdocs/               compatibility/manual state where present
org.sqlite             organization and application registry
work.sqlite            registry work/audit state
apps.sqlite            compatibility/migration database
backups/               default backup destination
```

The exact set depends on features used and migrations performed. JSON stores
use write-to-temporary-file plus atomic rename. Message append is flushed before
delivery. SQLite is loaded dynamically; if unavailable, bus, task, and workflow
operation can continue, but mutable registries are read-only and an online full
backup cannot be created.

Never edit live store files manually. Registry mutations can also rewrite the
hub INI, so back up the configuration and store together.

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
- copies the journal, cursors, tasks, workflows, configuration, and retained
  top-level JSON store files;
- writes sizes and SHA-256 digests to `MANIFEST`;
- assembles in a temporary directory and renames it only when complete; and
- protects the finished directory with owner-only permissions.

The artifact includes credentials. Treat it as a credential bundle: encrypt it
at rest, restrict access, keep it outside the repository and shared exchange,
and test recovery on an isolated host.

The built-in backup does **not** include the `wfhistory/` workflow undo
snapshots or legacy `appdocs/` files. Current application manuals are retained
in the SQLite registry after migration, but old migration material may still
matter to a particular installation. Back up those subdirectories separately
when their history is required. Use a filesystem snapshot or copy them while
the hub is stopped, protect them like the main backup, and restore them through
the same separately managed process; `tiza restore` does not restore them.

`tiza backup verify` is local and non-mutating. It checks manifest hashes,
requires a readable master credential in the saved configuration, and checks
that the database files carry valid SQLite headers. It is not a complete SQLite
integrity check; a periodic isolated restore is the stronger test. Verification
covers only files listed by the built-in backup; verify separately retained
subdirectories independently.

## Restore

Restore is a local operation on the hub host and replaces live state. First
identify the exact hub configuration and stop that hub:

```sh
sudo systemctl stop pizarra.service
PIZARRA_CONF=/etc/pizarra/pizarra.conf \
  tiza restore /srv/secure-backups/pizarra/pizarra-<timestamp> --dry-run
```

Review the printed configuration path, store path, backup path, and credential
warning. Then perform the explicit restore:

```sh
PIZARRA_CONF=/etc/pizarra/pizarra.conf \
  tiza restore /srv/secure-backups/pizarra/pizarra-<timestamp> --confirm
```

The restore command refuses to proceed while the target hub port answers,
verifies the backup before changing state, and moves current files into a
timestamped `.pre-restore-*` safety directory. Moving the complete old state
also prevents stale SQLite WAL or shared-memory files from replaying newer data
over the restored databases.

If the saved and current bus credentials differ—or cannot be compared—the
command stops before moving files. `--force` is a separate acceptance of that
fleet-wide credential consequence. After restore:

1. start the hub;
2. check teams and application registries;
3. inspect tasks, workflows, and recent messages;
4. confirm remote delivery and web startup;
5. retain the `.pre-restore-*` directory until validation is complete.

## Fleet releases and updates

The update channel serves an endpoint binary for a matching OS/CPU and a source
archive fallback. It never accepts an arbitrary download URL from the caller.

Prepare a release from a clean, committed tree:

```sh
make test
make publish
```

`make publish` stages artifacts before renaming them into `releases/` and writes
`VERSION` last. Point `[server] releases` at that directory. The hub offers an
update only when the published version exactly matches the running hub version;
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
