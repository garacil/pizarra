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

Node.js and npm are not part of the build or test toolchain.

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

## 2. Install and initialize the canonical layout

Install binaries and browser assets:

```sh
sudo make install
```

For a new machine, the first **implicit** root run creates the protected Unix
layout, generates one random master credential, and writes matching hub and
console files. `--migrate-only` performs that initialization and verifies the
empty SQLite registry without opening a listener or watchdog:

```sh
sudo /usr/local/bin/pizarra --migrate-only
```

The result is:

```text
/etc/pizarra/pizarra.conf       bootstrap/static hub settings, mode 0600
/etc/pizarra/tiza.conf          matching console identity, mode 0600
/var/lib/pizarra/.pizarra-hub.lock
                                persistent exclusive hub/restore lock, mode 0600
/var/lib/pizarra/releases/      endpoint release root, mode 0700
/var/lib/pizarra/org.sqlite     authoritative organization registry
/var/lib/pizarra/work.sqlite    task projection/history
/var/lib/pizarra/apps.sqlite    retained legacy compatibility database
/var/log/pizarra/pizarra.log    hub log
/usr/local/share/pizarra/web/apps/
```

The generated listeners are loopback-only and `[registry] authority = sqlite`.
If you supply `--config` or `PIZARRA_CONF`, the path is strict and no first-run
files are generated. An alternative manual installation may copy the public
examples into `/etc/pizarra`, but every placeholder secret must be replaced and
the directories/files must retain their documented modes.

`pizarra.conf` is not a team registry. Do not add new `[team:*]`, `[group:*]`,
`[project:*]`, or `[app:*]` sections; current organization state lives only in
`org.sqlite` and is changed through the hub.

## 3. Start the hub and register a local agent team

Start the hub in one terminal:

```sh
sudo /usr/local/bin/pizarra
```

In another terminal, create the team through the generated console identity:

```sh
sudo /usr/local/bin/tiza team add builder \
  "Implements and verifies assigned work" --session pizarra-builder
sudo /usr/local/bin/tiza team set builder workdir /absolute/path/to/the/project
sudo /usr/local/bin/tiza team set builder prompt \
  "Be concise. Report evidence and close completed tasks."
```

Give every agent a unique bound credential. Store that same value in a private
identity file such as `/etc/pizarra/agents/builder.conf`, then load it into the
registry without placing it in argument history:

```sh
sudo install -d -m 0711 -o root -g root /etc/pizarra/agents
sudo /usr/local/bin/tiza team set builder secret --file /secure/builder.secret
```

The identity file has this shape and must be mode `0600`, owned by the account
that runs the session:

```ini
[pizarra]
host = 127.0.0.1
port = 7010
secret = <the-exact-builder-secret>
self = builder
```

Configure the reviewed interactive agent wrapper as the tmux launch program:

```sh
sudo /usr/local/bin/tiza team set builder launch \
  "bash -lc 'export TIZA_CONF=/etc/pizarra/agents/builder.conf; exec /usr/local/bin/start-ai-agent'"
```

The hub watchdog creates `pizarra-builder` on its next pass and starts the agent
in the configured `workdir`. `launch` is executable code; use only a reviewed
command. If the hub/session uses another operating-system account, change the
file ownership, service `User`/`Group`, and registry `user` coherently.

## 4. Use the human console

The generated `/etc/pizarra/tiza.conf` identifies as `console` with the matching
master credential:

```sh
sudo /usr/local/bin/tiza chat
```

In the console:

```text
builder: Report your identity and current open tasks.
/task add builder Inspect the project and propose a verified first change
/task list open builder
/teams
/tree
```

Equivalent one-shot commands are:

```sh
sudo /usr/local/bin/tiza builder "Report your identity and current open tasks."
sudo /usr/local/bin/tiza task add builder \
  "Inspect the project and propose a verified first change"
sudo /usr/local/bin/tiza task list open builder
```

## 5. Add the web console

`pzweb` needs an inbox-only, identity-bound team with every administrative
family. Create it through the hub, not in `pizarra.conf`:

```sh
sudo /usr/local/bin/tiza team add pzweb \
  "Private operational web console" --session -
sudo /usr/local/bin/tiza team set pzweb secret --file /secure/pzweb-team.secret
sudo /usr/local/bin/tiza team set pzweb delegate \
  "team,group,project,app,task,workflow,watch,backup,update,header"
```

Install `/etc/pizarra/pzweb.conf` with the same bound team secret and a separate
HTTP password digest:

```ini
[pizarra]
host = 127.0.0.1
port = 7010
secret = <the-exact-pzweb-team-secret>
self = pzweb

[web]
listen = 127.0.0.1
port = 7080
allow_from = 127.0.0.1
host = 127.0.0.1:7080
origin = http://127.0.0.1:7080
static = /usr/local/share/pizarra/web/apps
user = operator
password_sha256 = <64-lowercase-hex-sha256-of-the-password>
```

The file must be a regular, non-symlinked file with permissions exactly `0600`.
Start it and open `http://127.0.0.1:7080/`:

```sh
sudo /usr/local/bin/pzweb
```

The browser uses the original HTTP password, not its digest. `pzweb` does not
open `org.sqlite` or parse registry files; every organization view and registry
mutation is proxied to the running hub over its authenticated bus connection.

## 6. Add a remote team host

Create a push-delivered team through the console identity:

```sh
sudo /usr/local/bin/tiza team add reviewer \
  "Reviews changes and verifies recovery" --remote 192.0.2.42:7011
sudo /usr/local/bin/tiza team set reviewer secret --file /secure/reviewer.secret
```

On that private host, create `/etc/pizarra/tiza.conf`:

```ini
[pizarra]
host = 192.0.2.10
port = 7010
secret = <reviewer-secret>
self = reviewer

[daemon]
listen = 192.0.2.42
port = 7011
secret = <hub-master-secret>
state = /var/lib/pizarra/tiza.state

[session:reviewer]
tmux_session = pizarra-reviewer
launch = <interactive-agent-command>
workdir = /srv/reviewer/project
```

The current push path authenticates hub-to-daemon delivery with the hub master
secret. Keep both ports private and prefer reverse dial when that credential
must not leave the control host. For reverse dial, set `dial = on` in the daemon
INI and `tiza team set reviewer dial on`, then clear the team host with
`tiza team set reviewer host -`.

## 7. Verify behavior

Run these checks before opening a listener beyond loopback:

```sh
/usr/local/bin/pizarra --version
/usr/local/bin/tiza --version
/usr/local/bin/pzweb --version
sudo /usr/local/bin/tiza ver
sudo /usr/local/bin/tiza fleet
sudo /usr/local/bin/tiza team list
sudo /usr/local/bin/tiza group list
sudo /usr/local/bin/tiza app list
sudo /usr/local/bin/tiza inbox --keep
```

Then test one immediate delivery, one queued delivery while a host daemon is
stopped, restart the daemon, and confirm exactly one terminal injection.

Continue with [Operations](operations.md) and [Security](security.md).
