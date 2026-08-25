# Limitations

These constraints are part of the current implementation. Some are deliberate
scope choices; others are candidates for future work. Plan deployments around
them rather than assuming an unimplemented safety or availability property.

## Availability and scale

- **Single hub:** there is no built-in leader election, replication, automatic
  failover, or multi-hub federation. The hub is the coordination and write
  availability boundary.
- **Operator-managed recovery:** backups, service supervision, capacity,
  disaster recovery, and upgrade rollout remain operator responsibilities.
- **Bounded live streams:** slow watchers can receive an explicit `gap` and must
  reload durable state. A watch stream is not an infinite reliable queue.
- **Startup journal compaction:** the hub protects pending and unconsumed
  messages and retains a recent window of 5,000 consumed messages when it
  compacts at startup. It is not a permanent archive of every acknowledged
  message.
- **One active reverse channel per team:** a second daemon cannot concurrently
  serve the same team for high availability.
- **No published scale target:** resource caps bound individual inputs and web
  connections, but the project does not currently publish benchmark-backed
  fleet, task, workflow, or throughput limits.

## Network and authentication

- **No transport encryption:** native bus, daemon push, and web traffic are
  cleartext. Shared-secret authentication does not hide credentials or content
  from a network observer.
- **Symmetric credentials:** there is no certificate identity, public-key
  request signature, hardware-backed identity, or automatic credential
  rotation.
- **Direct-push trust expansion:** a pushed endpoint daemon currently needs the
  hub master credential. Reverse dial avoids that credential on the remote host
  and is the preferred remote mode.
- **One web user:** `pzweb` has one configured Basic-authentication identity. It
  does not provide multiple browser accounts, per-user browser roles, external
  identity federation, or session revocation.
- **Password digest:** the web password is stored as an unsalted SHA-256 digest,
  not with a password-hardening function. Use a long random password and protect
  the config.
- **IPv4 web admission:** the current `pzweb` listener and `allow_from` model are
  IPv4-only.
- **Not proxy-aware:** web host/origin validation models direct cleartext HTTP.
  TLS termination and forwarded headers are not a first-class supported mode.
- **Private-network posture:** the suite is not hardened or packaged as a
  public Internet edge service.

## Execution isolation

- **`tmux` is required:** managed terminal delivery targets named `tmux`
  sessions; other terminal multiplexers and native process runners are not
  implemented.
- **Operating-system accounts are the isolation boundary:** teams sharing an
  account can potentially reach each other's files, processes, and terminal
  server. pizarra does not create containers or sandboxes.
- **Launch commands are trusted code:** an authorized `launch` value is passed
  to a shell. Registry validation does not make it safe.
- **Agent behavior is outside the guarantee:** delivery headers and workflow
  notices are instructions. The hub cannot prove that a receiver obeyed them or
  that submitted test evidence is true.
- **No content trust classifier:** messages and shared files can contain hostile
  or misleading instructions. Authentication identifies the pizarra sender; it
  does not establish that content is safe to execute.

## Workflow semantics

- **No dynamic replan while running:** graph structure is editable only in
  draft. Clone, abort/recreate, or use the explicit error protocol to change an
  active plan.
- **Phase barrier:** activation waits for all lower topological levels, not only
  direct predecessors. This favors comprehensible phases over maximum graph
  concurrency.
- **Human truth remains human:** strict mode requires non-empty completion
  evidence but does not execute or validate the claimed test.
- **One error gate per halted plan:** additional reports are logged while the
  current error is resolved; they do not create concurrent recovery tracks.
- **Finite snapshot retention:** only the newest 30 snapshots per workflow are
  retained.
- **Stable IDs, no rename:** workflows use names in cross-plan dependencies, so
  rename is intentionally absent.
- **Task projection is eventually reconciled:** after a partial storage failure,
  workflow truth may temporarily be newer than its linked task or notification.

## Files and storage

- **Small transfer channel:** native file transfer is capped at 10 MiB per file.
  It is meant for coordination artifacts, not large datasets or release storage.
- **Flat shared namespace:** the public file exchange exposes the root and one
  team directory level, not an arbitrary directory tree API.
- **Integrity, not provenance:** SHA-256 verifies complete transfer bytes; there
  is no digital signature or malware/content scan.
- **SQLite is mandatory for hub startup:** `org.sqlite` is the organization
  authority. Without a loadable SQLite library and a readable, upgradeable,
  completely projectable registry, the hub refuses to start. There is no
  read-only fallback to legacy INI registry sections.
- **Backup artifacts contain secrets:** confidentiality depends on external
  filesystem and storage controls.
- **Auxiliary history is outside the built-in backup:** `tiza backup` and
  `tiza restore` do not include `wfhistory/` workflow undo snapshots, legacy
  `appdocs/` files, the canonical `releases/` artifact tree, or content from the
  external shared/NFS root. The backup contains the hub config's shared-path
  reference only. Operators that require those records, cannot regenerate
  releases, or need shared data must protect and restore them separately with a
  coordinated external snapshot.
- **Linux-specific secure file handling:** browser shared-file operations rely
  on Linux descriptor facilities. The suite targets Unix-like systems, with its
  strongest tested operational assumptions on GNU/Linux.

## Web console

- **Static assets are preloaded:** a frontend change requires a `pzweb` restart.
- **Recent-tab cap:** Activity retains at most 300 messages in one browser tab.
  History must be used for durable pagination.
- **Projected feed:** the web Activity stream includes durable messages, not all
  native `sys` and `task` watch events.
- **No offline browser mode:** the browser is an operational client of the live
  hub, not a cached replica.
- **No arbitrary API pass-through:** the HTTP API exposes validated route
  families and intentionally does not accept raw native protocol commands.
- **Exact-origin deployment:** a web endpoint accessed through a differently
  named or differently schemed authority will reject mutations until the direct
  `host`/`origin` contract matches.

## Builds, platforms, and updates

- **Free Pascal toolchain:** source builds require Free Pascal and the platform
  C toolchain expected by the Makefile.
- **No fully static build:** threaded binaries use the system C runtime and
  dynamically load SQLite.
- **Limited published architectures:** the Makefile selects `x86_64`,
  `aarch64`, or an `i386` fallback for release naming. Other targets require
  validation and packaging work.
- **Endpoint-only fleet update:** the built-in channel updates `tiza` daemons.
  The hub, web server, frontend assets, configuration, and service units are
  upgraded through operator-controlled installation.
- **Locally trusted release root:** updates are hash-verified but not signed with
  an independent release key. Control of the hub or release directory is part
  of the update trust boundary.
- **Source fallback needs a compiler:** an endpoint without a matching binary
  artifact can use the source archive only when the configured build toolchain
  is present.

## Testing and compatibility

- **Minimal automated public test target:** `make test` currently builds and
  checks version entry points. It is not the full integration matrix described
  in [Testing](testing.md).
- **No formal wire specification version independent of the suite:** clients
  should use `ver`/capabilities, fail closed on unknown required behavior, and
  tolerate additive response fields.
- **No external consistency service:** delivery, task, and workflow durability
  depend on the hub host's filesystem and correct operational backup policy.

See [Architecture](architecture.md) for the implemented boundaries and
[Operations](operations.md) for mitigations.
