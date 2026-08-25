# Quick start

This guide creates a loopback-only installation with one local team, a human
terminal console, and an optional web console. Keep it on loopback until every
credential and operating-system boundary has been reviewed.

## 1. Install prerequisites

You need:

- Free Pascal and its standard units;
- GNU Make and GCC linker support;
- `tmux` for managed terminal sessions;
- `libsqlite3` at runtime for registry writes and audit history.

Check the compiler and build the suite:

```sh
./configure
make check
make
make test
```

`./configure` checks the required toolchain and supported release architecture,
then writes an ignored `config.mk` containing installation paths only. Run
`./configure --help` for `--prefix`, `--bindir`, and `--datadir`.

The build creates `pizarra`, `tiza`, and `pzweb` in the repository root.

## 2. Create private configuration

Copy the public examples with restrictive permissions:

```sh
install -m 600 conf/pizarra.conf.example conf/pizarra.conf
install -m 600 conf/tiza.conf.example conf/tiza.conf
install -m 600 conf/pzweb.conf.example conf/pzweb.conf
```

Generate separate long random values for:

- the hub master secret;
- each team secret;
- the web console's bound team secret;
- the web login password.

Never use the same value for the master and a team. Real configuration is
ignored by Git, but permissions and backup handling still matter.

## 3. Configure the hub

Use loopback, writable state paths, and one local team. Replace all angle-bracket
placeholders before starting.

```ini
[server]
listen = 127.0.0.1
port = 7010
secret = <master-secret>
master_console_only = on
header = short

[log]
path = /absolute/private/path/pizarra.log

[store]
dir = /absolute/private/path/store

[prompts]
global = Work through pizarra, report progress, and verify before completion.

[team:1]
name = builder
speciality = Implements and verifies the assigned work
prompt = Be concise. Report evidence and close completed tasks.
secret = <builder-secret>
tmux_session = pizarra-builder
launch = <interactive-agent-command>
workdir = /absolute/path/to/the/project
```

`launch` is executed by the service account and must start an interactive
terminal program that accepts pasted input. Treat this setting as code. Omit
the optional team `user` when the hub and session use the same account. Setting
`user` makes the hub invoke `su` and therefore requires a service topology that
is explicitly allowed to switch operating-system accounts.

Create a second `tiza` configuration for commands sent from inside that managed
session:

```ini
[pizarra]
host = 127.0.0.1
port = 7010
secret = <builder-secret>
self = builder
```

Point the session at it with `TIZA_CONF` in the environment or include that
environment assignment in the launch command. Identity comes from `self`; a
normal command-line `--from` does not override it.

## 4. Configure the human console

Edit `conf/tiza.conf`:

```ini
[pizarra]
host = 127.0.0.1
port = 7010
secret = <master-secret>
self = console
```

Start the hub in one terminal:

```sh
./pizarra --config conf/pizarra.conf
```

Start the human console in another:

```sh
./tiza --config conf/tiza.conf chat
```

The hub watchdog creates `pizarra-builder` if it is missing. In the console:

```text
builder: Report your identity and current open tasks.
/task add builder Inspect the project and propose a verified first change
/task list open builder
/teams
/tree
```

From a regular shell, the equivalent direct commands are:

```sh
./tiza --config conf/tiza.conf builder "Report your identity and current open tasks."
./tiza --config conf/tiza.conf task add builder "Inspect the project and propose a verified first change"
./tiza --config conf/tiza.conf task list open builder
```

## 5. Add the web console

The web console intentionally needs a powerful but identity-bound credential.
Add an inbox-only team to `pizarra.conf`:

```ini
[team:90]
name = pzweb
speciality = Private operational web console
secret = <web-team-secret>
tmux_session = -
delegate = team, group, project, app, task, workflow, watch, backup, update, header
```

Restart the hub after editing the declarative configuration. Then edit
`conf/pzweb.conf`:

```ini
[pizarra]
host = 127.0.0.1
port = 7010
secret = <web-team-secret>
self = pzweb

[web]
listen = 127.0.0.1
port = 7080
allow_from = 127.0.0.1
host = 127.0.0.1:7080
origin = http://127.0.0.1:7080
static = web/apps
user = operator
password_sha256 = <64-lowercase-hex-sha256-of-the-password>
```

`pzweb.conf` must be a regular, non-symlinked file with permissions exactly
`0600`. Start the service:

```sh
./pzweb --config conf/pzweb.conf
```

Open `http://127.0.0.1:7080/` and authenticate with the configured user and the
original password, not its digest.

## 6. Add a remote team host

On the hub, replace a local session target with a remote push target:

```ini
[team:2]
name = reviewer
speciality = Reviews changes and verifies workflow recovery
secret = <reviewer-secret>
host = 10.0.0.42:7011
```

On that private host, create `tiza.conf`:

```ini
[pizarra]
host = 10.0.0.10
port = 7010
secret = <reviewer-secret>
self = reviewer

[daemon]
listen = 10.0.0.42
port = 7011
secret = <hub-master-secret>
state = /var/lib/tiza/tiza.state

[session:reviewer]
tmux_session = pizarra-reviewer
launch = <interactive-agent-command>
workdir = /srv/reviewer/project
```

This example keeps the daemon and managed session under the same operating-
system account. Configure a session `user` only when the daemon is intentionally
privileged to switch accounts; the unprivileged example service cannot do so.

The current push path authenticates hub-to-daemon delivery with the hub master
secret. This places that credential on the remote host. Keep both ports private
and prefer reverse dial when distributing the master is unacceptable.

For a host that cannot accept inbound connections, set `dial = on` in the
daemon section and `dial = on` on the matching hub team, with no `host` value.

## 7. Verify behavior

Run these checks before opening any listener beyond loopback:

```sh
./pizarra --version
./tiza --version
./pzweb --version
./tiza --config conf/tiza.conf ver
./tiza --config conf/tiza.conf fleet
./tiza --config conf/tiza.conf inbox --keep
```

Then test one immediate delivery, one queued delivery while a host daemon is
stopped, restart the daemon, and confirm exactly one terminal injection.

Continue with [Operations](operations.md) and [Security](security.md).
