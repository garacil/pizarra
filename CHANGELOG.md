# Changelog

## 1.1.23 — Crash-safe startup and session preservation

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
