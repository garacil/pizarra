# Changelog

## 1.1.34 - The audit trail names who opened the shell

- A host could see THAT a shell or attach was opened on it, but not BY WHOM.
  The daemon logged only the target team and the local account, so on a hub
  with a permissive trust list every caller looked identical from the machine
  being entered, and the only usable trail lived on the hub - a different
  machine, under a different owner. Both endpoints now log the calling team:
  `shell opened by <team> -> ...` and `attach opened by <team> -> ...`.
- Two distinct causes, and the second was the worse one. On the push route the
  hub already sent the caller in the handshake and the daemon simply ignored
  it. On the dial route the control line carried no caller field at all, so the
  daemon could not have logged it, AND the hub's own dial line named the daemon
  that dialled back instead of the team that asked - recording the target as
  its own caller. `shell_open` and `attach_open` now carry `from`, and the
  rendezvous record keeps the caller separately from the dialling daemon.
- Reported independently by two host owners after 1.1.33, from their own logs.
  Neither could answer "who just opened a root-capable shell on my machine",
  which is the question the feature has to be able to answer.

## 1.1.33 - The internal shell: administer any host from any team

- New `tiza shell <team>`: an interactive login shell on the MACHINE where a
  team runs, relayed by the hub over the same three routes as attach. The point
  is the dial-in endpoints, which have no inbound route at all, so the shell
  rides the reverse channel they already hold open. A host with no declared tmux session can be reached
  too: a shell belongs to the machine, not to a session.
- The verb is `shell`, not `console`, and deliberately so: `tiza console "..."`
  already means SEND to the operator identity, the documented way a team
  replies, so a verb of that name would shadow it for every team. `attach` and `shell` were also added to the reserved verb list,
  which had been missing `attach` since 1.1.28.
- It opens as an ordinary configured account, never root. `sudo su` inside is
  how the operator escalates, which keeps that step in the host's own sudo
  trail. `[daemon] shell = on` with no `[daemon] shell_user`, or one naming
  `root`, is refused rather than guessed.
- BOTH ends must opt in, with their own keys, independent of attach: the hub's
  `[server] shell_local` + `shell_user` + `shell_trust`, and the target host's
  `[daemon] shell` + `shell_user`. The host's decision is final - the hub can
  never override a machine that has the shell off. Enabling attach does not
  grant a shell and vice versa; a harness proves both directions.
- Unlike attach, the pty is sized to the VIEWER (a shell has one caller and no
  session to disturb), there is no read-only mode (a shell you cannot type into
  is useless, not a lesser grant), and Ctrl-b is an ordinary byte so tmux works
  inside. Leave with `exit`/Ctrl-D; `Ctrl-] q` is the emergency escape.
- Bounds are its own: 4 per hub, 2 per target HOST, so open attaches can never
  make the fleet unadministrable. Both ends log every open and close - the hub
  records who, where and which route, the daemon records as whom. Session
  CONTENT is deliberately not recorded: a sudo password would land in a
  replicated, fleet-readable store. The host's sudo and audit trail is where a
  transcript belongs.
- Nothing here creates, kills or renames a tmux session; the shell is a private
  pty child and `scripts/test-no-destructive-tmux.sh` stays green.
- Deployment: autoupdate ships the binary only, and both new keys default off,
  so an updated endpoint gets the capability inert until its `tiza.conf` is
  edited and the unit restarted. No systemd unit change is needed.

## 1.1.32 - Crash-loop guard for a wrong-owner config

- A `/etc/pizarra/tiza.conf` owned by a non-root uid is correctly refused, but on
  a `Restart=always` unit it looped ~196 times at RestartSec=5 on one host, and a
  `cp -p` rollback (what tiza's own updater uses for binary backups) restores such
  a wrong-owner file. Two guards:
  - `systemd/tiza.service` (and `pizarra.service`, `pzweb.service`) now carry
    `StartLimitIntervalSec=60` + `StartLimitBurst=5`: a config the process refuses
    at startup surfaces as a FAILED unit after 5 tries, not an endless loop; a
    transient failure that recovers in a couple of restarts is unaffected.
  - the credential-ownership error now prints the exact remedy, e.g.
    `... is owned by uid 1000 - fix: chown 0:0 /etc/pizarra/tiza.conf`.
- The unit change reaches a host only through `make install`/a fresh deploy
  (autoupdate replaces the binary, not the unit); the error-message change ships
  with the binary. Reported by an endpoint agent from measured host state.

## 1.1.31 - Attach detach with Ctrl-b d; honest version and docs

- `tiza attach` also detaches with **Ctrl-b d** (tmux's own prefix + detach),
  in read-only and write alike. It is intercepted client-side, so it is not
  forwarded (no switch-client into other sessions), and it is typeable on every
  keyboard layout - unlike Ctrl-] (AltGr gymnastics on e.g. a Spanish layout),
  which still works too. The banner names both.
- Fixed a misleading error: the client said `this hub does not support attach
  (needs 1.2.0)` when a hub replied `unknown cmd`. Attach shipped in 1.1.28, not
  1.2.0; it now reads `needs 1.1.28 or newer`.
- The daemon's "attach not enabled" refusal now names both keys
  (`[session:TEAM] attach` and the host-wide `[daemon] attach`), and the tiza
  app doc documents `tiza attach`, both keys, `attach_local` and `attach_trust`,
  which were undocumented in the operational manual.
- Hardened the `/proc/<pid>/environ` read in `scripts/pzpty-test.pas`: it read
  empty during the fork->execve window, so the whole read retries now, not just
  the open.

## 1.1.30 - Attach trust: any team may drive any team

- `[server] attach_trust` names the identities that may `tiza attach` AND write
  ANY team - a comma/space list, or the keyword `all` for every authenticated
  team. Empty (default) keeps the strict rule: only `console` writes, a
  delegated team reads. With `all`, each team attaches with its OWN bound
  credential, so no shared console secret has to live on a remote box, and the
  hub logs the real identity (`builder -> planner (write)`), not `console`.
- `[daemon] attach` is a host-wide default for that daemon's sessions: one
  `attach = on` opts in every `[session:TEAM]` on the host (a session may still
  set `attach = off`). Previously every session needed its own `attach = on`.
- The consent model is unchanged and still off by default: a local team needs
  `[server] attach_local = on`, a remote team needs `attach = on` (now settable
  once per host). `attach_trust` is the operator's explicit statement of WHO may
  drive; the per-host `attach` is the host owner's statement of WHICH panes may
  be reached.
- New harness `scripts/test-attach-trust.sh`. Also hardened the flaky
  `/proc/<pid>/environ` read in `scripts/pzpty-test.sh` (it reads empty during
  the fork->execve window; the whole read now retries, not just the open).

## 1.1.29 - Attach compiles on the macOS endpoint

- `pzattach` declared its saved/raw terminal state as `TTermios`, which the FPC
  RTL defines only on Linux (`TTermios = Termios`); on Darwin only `Termios`
  exists, so the type resolved to `<erroneous type>` and `tcsetattr` refused it.
  `tiza daemon` pulls in `pzattach` for the `tiza attach` CLI, and the macOS
  endpoint compiles the shipped source during its self-update, so 1.1.28 aborted
  that build (`pzattach.pas: Incompatible type ... expected "termios"`) and the
  endpoint correctly rolled back and stayed on its previous release. The state is
  now typed `Termios`, which the RTL defines on both platforms.

## 1.1.28 - Attach any team from any team

- `tiza attach <team> [--write]` opens a raw terminal into a team's tmux
  session, relayed by the hub, and now reaches EVERY route: a LOCAL team on the
  hub host, a PUSH team on a reachable daemon, and a DIAL-in team behind NAT.
  The client only needs to reach the hub, so it runs from any host, a dial-in
  one included. Detach with Ctrl-] then q.
- Read-only by default: the viewer's keystrokes are dropped at the hub, the
  authoritative gate. Write is console-only; a delegated team is silently
  downgraded to read-only and the reply says so.
- Consent is explicit and OFF by default. A local team needs `[server]
  attach_local = on` on the hub; a remote team needs `[session:TEAM] attach =
  on` in its host's `tiza.conf`. The host owner decides whether its agent
  terminals may be viewed or driven, exactly as with activity sampling.
- The session is never resized to fit a viewer: the relayed tmux client is
  sized to the session and marked ignore-size.
- Routes: local (the hub spawns the tmux client under a pty and pumps it), push
  (the hub connects to the daemon, which spawns the client and relays back),
  dial (the hub pushes an `attach_open` control line down the reverse channel;
  the daemon dials the hub back with an `attach_join` connection, paired to the
  waiting viewer by an unguessable token bound to the target team). Bounded to
  8 attaches per hub and 2 per team.
- New harnesses `scripts/test-attach.sh` (local route) and
  `scripts/test-attach-routes.sh` (push, dial, and the consent gate), on a
  private tmux socket with no `kill-server`.
- Portability fix carried in the same work: `pzchat.TermWidth` uses `termio`'s
  `TIOCGWINSZ`/`TWinSize` instead of a hardcoded Linux request number, so the
  console reads the real width on the macOS endpoint instead of falling back to
  80 columns.

## 1.1.27 - No path may end a session

- `scripts/test-watchdog-session.sh` addressed the LIVE tmux server whenever it
  ran from inside a tmux pane: tmux chooses its socket from `TMUX` before it
  looks at `TMUX_TMPDIR`, so the private directory the harness set was ignored,
  and the `kill-server` in its cleanup ended every session on the hub host
  (2026-09-07). The harness now removes `TMUX`/`TMUX_PANE` from its
  environment, names its private socket explicitly with `-S` on every call,
  checks on the hub process that no `TMUX` was inherited, proves that a hub
  restart leaves an existing session untouched, and contains no `kill-server`:
  it removes the two sessions it created, by exact name, and the private
  server exits by itself.
- `systemd/pizarra-tmux.service` and `systemd/pizarra.service` carry
  `KillMode=process`, as `tiza.service` already did: no stop or restart of a
  shipped unit can reach a tmux server or the agent sessions inside it.
- New static guard `scripts/test-no-destructive-tmux.sh`: no product source
  issues a tmux verb that ends, replaces or renames a session, every unit that
  may hold a tmux server carries `KillMode=process`, and no script in the tree
  contains `kill-server`.
- The invariant is now documented in `docs/operations.md`: the hub and the
  daemon never kill, replace, rename or relaunch an existing session, no
  configuration key enables it, a hub that stops leaves every session open and
  a hub that starts uses the sessions it finds.

## 1.1.26 - Trusted ancestor links (macOS endpoint runtime fix)

- `pzlayout.PzResolveTrustedPath` resolves ancestor symbolic links before the
  credential and runtime-directory rules are applied, and every rule is then
  enforced on the resolved location. A link is followed only when it is owned by
  `root` or the runtime uid; one owned by anybody else is refused by uid, as is
  a chain deeper than 32. The final component is never followed, so a credential
  that is itself a symbolic link is still refused.
- Why: `/etc` and `/var` are themselves symbolic links into `/private` on macOS,
  so the previous literal rule - no symbolic link in any path component - made
  every canonical path illegal on that platform. An endpoint there loaded no
  configuration, exited, was restarted by its supervisor and looped every few
  seconds; only a hand-written `--config` pointing at `/private/...` avoided it.
- The protection is unchanged: redirecting a resolved path still requires write
  access to a directory that the group/other-writable rule refuses, and refusals
  now name the resolved path, which is the one that actually failed.
- New harness `scripts/test-trusted-path-resolution.sh` covers all four cases.
- Endpoint documentation for two silent misconfigurations. A team whose host has
  no `[session:TEAM]` block is refused by the daemon, recorded by the hub as an
  ordinary queueing event and never reported, so its deliveries accumulate while
  `tiza fleet` still reports the host `ONLINE` and only a delivery high-water
  mark stuck at zero shows it. And a `launch` command needs an absolute binary
  path plus an explicit `HOME`, because a pane the daemon creates inherits an
  empty one and a login shell then builds `PATH` without the agent's own
  directory, so the session exits immediately on every watchdog pass.

## 1.1.25 - Portable directory opens (macOS endpoint build fix)

- `pzlayout.PzOpenDirFd` replaces every direct `O_DIRECTORY` open. The flag is
  defined only in FPC's Linux RTL (`rtl/linux/ostypes.inc`), and the macOS
  endpoint compiles the shipped source during its own self-update, so naming it
  unconditionally aborted that build with `Identifier not found "O_DIRECTORY"`
  and left the host on its previous release. Where the flag is absent the
  primitive proves the type on the OPEN DESCRIPTOR with `fstat`, which pins the
  inode exactly as the flag does, and reports `ENOTDIR` for a non-directory.

## 1.1.24 - Truthful host-session report

- `pizarra --host-session NAME` now says which of the two things happened:
  `created with the hub inside`, or `already exists; existing sessions are
  always preserved`. One unconditional message for both cases read as "another
  supervisor is already running the hub".
- `pztmux.EnsureSessionReported` reports creation from the status of our own
  `new-session`, so a session another creator won the race for is not claimed;
  it costs no extra tmux probe and `EnsureSessionDetailed` is unchanged for
  every watchdog call site.

## 1.1.23 — Crash-safe startup and session preservation

### Console and Telegram group messaging

- `tiza chat` accepts `/msg @group` and bare `@group` as the same multi-line
  composition flow used for a team; `.` sends and `/cancel` discards. The
  existing `@group: text` shorthand remains an immediate group broadcast.
- The Telegram bridge provides the same group composition flow with independent
  per-user drafts, so two phone operators cannot mix or send each other's text.
- Interactive `/help commands` now uses framed, alias-aware command tables and
  makes the group forms explicit; redirected output remains script-friendly.

### Session lifecycle

- Local hub and daemon watchdogs now treat an existing tmux session as final:
  they never replace it, never issue its launch command again, and only refresh
  ownership metadata. A missing session is created only when a reviewed,
  non-empty launch command exists.
- Failed creates retain the durable delivery and log a bounded diagnostic from
  tmux. Missing work directories and manual/inject-only sessions are reported
  accurately instead of producing false respawn success every watchdog tick.
- Local delivery now uses the configured team work directory when it must
  create a missing session.
- `pizarra --host-session NAME` provides an opt-in visible-pane supervisor. The
  Pizarra binary itself preserves an existing session or creates the missing
  hub session exactly once; it has no replacement or destructive path.
- The systemd deployment uses a dedicated tmux-server boundary with
  `exit-empty off`, preventing a hub service restart or failed transactional
  upgrade from collecting live agent sessions into the hub service cgroup.

### Startup, configuration, and health

- Hub and daemon listeners bind before watchdogs, dial threads, workflow
  reconciliation, shared-file publication, or readiness output can run. A port
  collision is now a read-only startup failure.
- `tiza --health [--wait SECONDS]` validates authenticated typed version and
  capability replies, credential binding, and exact suite-version agreement.
  `pzweb --health` proves that its configured TCP listener is reachable.
- Private configuration loading now requires the final mode-`0600` file to be
  owned by the runtime uid both before and after its descriptor-pinned open.
- First-run credential publication now uses a private, flock-protected recovery
  journal. Interrupted client-first or hub-first publication resumes with the
  original secret; a stale unlocked journal is recoverable, while an unrelated
  existing identity is never overwritten or guessed.
- Configure-time binary and data directories are compiled into runtime defaults
  and verified during packaging, including non-default prefixes.

### Installation and verification

- `make install` is now transactional and accepts only artifacts certified by
  `make test`. It stages and hashes the payload, snapshots prior files, state,
  modes, ownership, and service state, migrates before startup, and commits its
  manifest only after authenticated health succeeds.
- Explicit `make adopt` performs the first manifest-backed cutover from a
  stopped legacy deployment after matching an exact reviewed tmux inventory.
  Rollback preserves the tmux boundary whenever any session exists.
- Manifest-driven uninstall refuses modified payload and refuses to stop the
  tmux boundary while managed sessions remain. `DESTDIR` installation is a
  host-isolated packaging path with no service, state, or session effects.
- New regression coverage exercises transactional installation, custom
  prefixes, bind-before-ready behavior, crash-resumable first run, watchdog
  handling of manual sessions, and a fully hermetic proof that host-session
  launch is create-once and non-destructive.
- README, CLI, architecture, quick-start, operations, and testing references now
  document the same installer, health, recovery, and session-preservation
  contracts in English.

## 1.1.22 — Pizarra 1.1 (first GitHub release)

This is the first tagged public release of the `pizarra`, `tiza`, and `pzweb`
suite. It continues the deployed 1.1 series after 1.1.21. The `1.2.0` value
that appeared on the untagged public development branch was a placeholder: it
had no tag, GitHub Release, or production deployment and is not part of the
release history.

### Coordination and autonomy

- Durable journal-before-delivery messaging, ordered retry, cursor-based inbox,
  live watch streams with explicit gaps, and deduplicated terminal injection.
- Local tmux session supervision plus remote direct-push and preferred
  reverse-dial delivery, with reviewed terminal-agent launch commands. A host
  daemon tags each managed session with its identity-specific Tiza
  configuration so a bare client invocation keeps the intended identity.
- Durable tasks and dependency-aware workflows with branches, joins, phase
  barriers, strict completion evidence, human gates, halt/fix/independent
  verification, reminders, snapshots, undo, restore, and export.
- Team, group, project, application, manual, and relation management through
  authenticated CLI, terminal-console, native-protocol, and web operations.
- Persisted per-group permission-block handling: normal operator alarm or
  deliberate log-only policy, exposed through Tiza and pzweb.

### Configuration and state

- Canonical Unix layout: static and identity configuration below
  `/etc/pizarra`, durable state and SQLite below `/var/lib/pizarra`, logs below
  `/var/log/pizarra`, and installed web assets below
  `/usr/local/share/pizarra/web/apps`.
- The endpoint release root is normalized to the private absolute
  `/var/lib/pizarra/releases` directory. Migration preserves a verified stable
  byte-for-byte artifact snapshot, and publication stages all artifacts with
  `VERSION` committed last.
- `org.sqlite` is the sole live authority for the organization registry. Legacy
  INI registry sections are guarded one-time migration input and are removed
  only after verified reconciliation and backup.
- Secure first-run initialization creates private canonical directories and
  matching hub/console credentials without opening a listener in
  `--migrate-only` mode.
- Identity-preserving configuration resolution supports explicit paths,
  environment selection, and daemon-tagged tmux sessions while failing closed
  on a missing selected file.
- Lossless migration and verified retirement tools move checkout-based runtime
  configuration/state outside the repository and retain rollback lineage.
- Optional shared/NFS exchange paths remain external and configurable. Hub and
  pzweb use one identical mount reference; migration preserves both references
  without copying the tree, and built-in backup/restore excludes its content.

### Safety, web, and recovery

- `pzweb` provides eight authenticated operational views over a strict HTTP
  adapter; it never opens the registry database or maintains a competing copy.
- Bound per-team credentials, scoped delegation, exact JSON shapes, input size
  limits, exact Host/Origin validation, IPv4 admission rules, and guarded
  no-follow file access define the current private-network security boundary.
- Credential-bearing INI files are parsed from descriptor-pinned mode-`0600`
  handles after rejecting symlink components and unsafe writable ancestors;
  quoted values retain consistent semantics across typed loaders.
- Chunked transfers use exact offsets, staging, collision-safe publication, and
  whole-file SHA-256 verification. Local/NFS sharing exclusively reserves a
  private regular inode before copying and publishes mode-`0644` bytes only
  after completion, closing the preplanted-temporary-symlink race.
- Backups use a coherent snapshot barrier and SQLite online backup, publish an
  exact digest manifest, and reject unlisted payload. Restore shares the hub's
  persistent lifetime lock, preserves the previous state, and retains live
  owner identities.
- The endpoint update channel verifies size, digest, and version, installs
  atomically, and rolls back a failed candidate.

### Distribution and documentation

- Warning-fatal release/debug builds, version smoke checks, focused bootstrap,
  private-config, shared-copy, migration, retirement, and group-policy
  harnesses, plus an optional direct-Chromium UI regression and a documented
  isolated integration matrix. No Node.js or npm toolchain is required.
- Public configuration examples contain no runtime registry copies or real
  credentials.
- The real-browser gallery includes focused team, group, and application views
  plus a scrolling workflow animation built from the shipped HTML, CSS, and
  JavaScript with synthetic public data.
- The README, source-grounded reference set, and project wiki document the
  architecture, configuration, CLI, protocols, web surfaces, operations,
  security boundaries, tests, and known limitations for suite 1.1.22.
