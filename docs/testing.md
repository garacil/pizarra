# Testing

The public tree provides compiler-gated builds and binary version smoke checks.
It does not currently ship a complete automated end-to-end harness. Release
confidence therefore requires both `make test` and an isolated integration
exercise of the features being changed.

## Build gates

Check the toolchain and build optimized binaries:

```sh
./configure
make check
make test
```

`make test` performs a release build of `pizarra`, `tiza`, and `pzweb`, then
runs each binary's `--version` path. Compiler warnings are treated as errors.
This catches compilation, linking, and version-entry-point failures; it does not
open sockets or mutate a store.

Build with runtime checks and debug information before investigating memory,
range, overflow, or concurrency failures:

```sh
make debug
./pizarra-debug --version
./tiza-debug --version
./pzweb-debug --version
```

Compiled units are isolated under `build/release`, `build/debug`, and
`build/tiny`; changing targets cannot silently reuse units produced with a
different compiler flag set.

The public CI checkout and test path use shell tooling, Free Pascal, SQLite,
and tmux. They do not install or invoke Node.js, npm, or a JavaScript package
runner; browser assets are shipped directly and must keep that property.

`make static` intentionally fails because the threaded programs use the system
C runtime and load SQLite dynamically. Do not treat that failure as a test
regression.

The repository includes focused regression harnesses. Each creates only a
disposable temporary tree, below `/tmp` in the default environment:

```sh
scripts/test-bootstrap-layout.sh
scripts/test-private-config.sh
scripts/test-group-onblock.sh
scripts/test-chat-group-compose.sh
scripts/test-pzshare-symlink.sh
scripts/test-migrate-release-layout.sh
scripts/test-retire-repo-runtime-conf.sh
scripts/test-install-service.sh
scripts/test-pzweb-readiness.sh
scripts/test-session-preservation.sh
scripts/test-watchdog-session.sh
```

The bootstrap harness compiles the real Pascal layout implementation and checks
mode `0711` configuration, mode `0700` state/release/log directories, matching
mode-`0600` hub/client credentials, the generated canonical release path,
non-overwriting repair of a missing release directory, rejection of unsafe
release permissions, lock cleanup, and coherent systemd `StateDirectory`
ownership. The private-config harness compiles a disposable Pascal client
against the real typed loaders. It checks quoted-value semantics, final and
ancestor symlink rejection, exact mode-`0600` enforcement, rejection of a
non-sticky writable ancestor, and that a pathname replacement cannot redirect
an already opened descriptor. The shared-copy harness compiles the real
`pzshare` implementation, preplants a temporary-name symlink to a protected
file, and proves that the target and adversarial link remain untouched while
the payload is published as an exact mode-`0644` regular file. The
release-layout harness verifies a
non-mutating dry run; exact preservation of entry names, types, empty
directories, and file bytes; mode `0700` on the canonical release root; an
idempotent canonical rerun and final lineage record;
rejection of conflicting non-empty trees before destination mutation; and the
mandatory explicit source for a relative legacy release path. The retirement
harness exercises both dry-run and confirmed repository-runtime retirement,
including canonical release-path validation. Run them whenever migration,
canonical paths, source archival, release publication, or retirement checks
change. None operates on `/etc/pizarra`, `/var/lib/pizarra`, the checkout's
`.private` tree, or live tmux sessions.

The installer harness stages only below a disposable `DESTDIR`. It verifies
that configured binary/data paths reach compiled defaults, rendered examples,
and systemd units; rejects a publication path different from the certified
build; checks idempotent reinstall; injects a post-payload failure and compares
the restored bytes and metadata; checks manifest-driven uninstall; and proves
that explicit first-cutover adoption can replace and record a pre-existing
payload inside the disposable root. The
web-readiness harness starts an isolated loopback hub and web console, proves
that health fails before bind and succeeds after a real TCP connection, then
proves a second server fails promptly on the occupied port without claiming it
is listening. The watchdog-session harness uses a private tmux socket and proves
that a configured launch is created and ownership-tagged while an absent manual
session with no launch is neither fabricated nor falsely logged as respawning.
The session-preservation harness is stricter and entirely hermetic: a fake
`tmux` executable proves that `pizarra --host-session` creates an absent hub
session exactly once, performs only an existence probe on the second call, and
has no destructive command path. It never connects to any tmux server.

The chat-group-compose harness starts an isolated loopback hub with inbox-only
members. It proves that `/msg @group` and a bare `@group` both use the existing
multi-line state machine, preserve all lines until `.` sends, and that
`/cancel` leaves no durable group message. It also checks that `/help commands`
distinguishes group composition from the immediate `@group: text` shorthand.
It never starts or contacts tmux.

## Isolated integration environment

Use a temporary directory, loopback-only listeners, new disposable secrets,
and ports that do not overlap a live installation. Do not point tests at a
production config or store.

The smallest useful topology contains:

- one hub;
- a console identity using the master credential;
- two inbox-only teams with distinct bound credentials;
- one bound web identity with all required delegated families;
- the bundled web assets; and
- a temporary shared directory when file operations are under test.

Use exact `0600` mode for the web config. Keep all listeners on `127.0.0.1`.
Stop the isolated hub and remove only the known temporary directory when the
test is complete.

## Core integration matrix

### Authentication and authorization

- An empty, wrong, or unknown credential is rejected.
- A team credential cannot claim another identity.
- A team credential cannot call an undelegated family.
- A deliberately delegated family succeeds without granting unrelated access.
- Team credentials are unique and differ from the master credential.
- With `master_console_only = on`, the master credential cannot act as a team.

### Durable messaging

- A direct message receives a monotonic sequence.
- An offline destination returns queued state and receives the message later.
- Inbox peek does not advance the cursor.
- Paged `after` reads do not consume messages, including `after=0`.
- `ack` advances only to an eligible sequence and rejects a value above it.
- A group broadcast creates one durable entry per selected destination and
  reports partial delivery accurately.
- In `tiza chat`, `/msg @group` and bare `@group` compose until `.`; `/cancel`
  must not create a group message, while `@group: text` remains immediate.
- Restarting the hub preserves journal order and cursor state.

### Terminal delivery

- Multiline text arrives as one bracketed paste followed by one Enter.
- A lost delivery acknowledgement is retried.
- A persisted daemon receipt acknowledges a duplicate sequence without a
  second terminal paste.
- An unwritable receipt-state path is visible and does not pretend to provide
  restart-safe deduplication.
- A declared missing session is recreated, while removing its configuration
  does not kill an existing session.

Test remote push and reverse dial separately. Reverse dial must reject a claimed
team outside the bound credential's configured service scope and must refuse a
second active channel for the same team.

### Watch streams

- Replay starts strictly after the requested cursor.
- A normal team sees only traffic to or from itself.
- Delegated watch observes the intended wider scope.
- Keepalives do not alter durable message state.
- Queue/replay overflow, unavailable history, and a cursor ahead of the journal
  produce explicit `gap` events and require reload.

### Tasks and workflows

- Parent/child task integrity and terminal-state transitions are enforced.
- A workflow rejects missing dependencies and cycles.
- Parallel siblings activate together and the next topological level waits for
  all lower-level siblings.
- Activation creates one linked task; reconciliation repairs a missing
  projection without duplicating it.
- Strict mode rejects completion without evidence.
- A console-owned approval gate cannot be closed by a non-console identity.
- An error halts every branch and preserves the previously active set.
- The fixer cannot verify its own repair; failed verification stays halted;
  successful independent verification resumes the correct state.
- Cross-workflow completion activates eligible dependent work.
- Snapshot history, named undo, clone, save/restore, and exports preserve stable
  step IDs and valid dependencies.
- Abort cancels open linked tasks; deleting a workflow does not erase task
  history.

### Registries

For the persisted group permission-block policy, build the debug binaries and
run the focused disposable harness:

```sh
make debug
scripts/test-group-onblock.sh
```

The harness creates its fixture only below `/tmp`. It covers console, group
boss, and ordinary-member authorization; `alarm`, `log`, and `default` input
validation; SQLite persistence across a hub restart; and the value returned by
`group list`.

An additional local browser regression runs the repository's real
`web/apps/manage.js` in Chromium without Node.js, npm, Playwright, or another
JavaScript package runner:

```sh
PIZARRA_TEST_CHROMIUM_BIN=chromium \
  scripts/test-group-onblock-browser.sh
```

It requires Python 3 and a Chromium-compatible executable, starts a strict
loopback fixture server, and keeps its browser profile and captured output
below `/tmp`. It checks the rendered `when blocked: log only` card, the exact
`default`, `alarm`, and `log` selector values, and the exact
`POST /api/group/builders/onblock` body `{"onblock":"default"}`. This test is
optional for local validation because Chromium is not a public-CI dependency.

The focused organization screenshots and scrolling workflow animation are
also reproducible from the shipped browser source and synthetic Atlas fixture:

```sh
scripts/capture-web-showcase.sh
```

This optional documentation target requires Python 3, Chromium, `png2pnm`, and
`gifbuild`. It renders `web/apps/index.html` and the production CSS/JavaScript
directly; it does not require or invoke Node.js, npm, Playwright, Puppeteer, or
an external JavaScript runtime. Pass an existing output directory as its first
argument to keep the generated files separate from `screenshots/`.

- A missing implicit canonical installation creates matching mode-`0600` hub
  and console credentials plus private state/log directories; an explicitly or
  environmentally selected missing config fails without fallback/bootstrap.
- A second hub opening the same store fails on the persistent lifetime lock,
  including the interval before the first hub starts listening; managed child
  processes do not inherit that descriptor across `exec`.
- Legacy team/group/project/app input migrates into `org.sqlite` with exact
  counts, policies, manuals, and relations, then disappears from the active
  bootstrap INI only after verification and an owner-only backup.
- A second `--migrate-only` run is idempotent: it preserves registry counts and
  does not recreate INI registry sections or another cutover marker.
- Team parent cycles and missing references are rejected.
- Project and group administrators have only documented authority.
- Removing an object still referenced by open work or relations is refused.
- Application ownership, project roles, manuals, history, and undo survive a
  hub restart.
- When SQLite is unavailable, corrupt, or cannot be projected completely, hub
  startup fails visibly; no partial INI registry is served.

### Files and transfers

- Traversal, encoded separators, dot segments, NUL, and invalid basenames are
  rejected.
- Symlinks are not followed.
- Existing files are not overwritten; collisions produce a distinct name.
- Wrong offsets, malformed base64, excess sizes, and bad final SHA-256 digests
  fail without publishing a partial file.
- A verified upload/download round trip preserves exact bytes.
- Non-empty directory deletion requires explicit recursive intent and reports
  partial outcomes when the tree changes concurrently.

### Web console and API

- Startup rejects permissive or symlinked configuration, wildcard listeners,
  invalid allowlists, incoherent host/origin, missing assets, unbound identity,
  console impersonation, and any missing delegated family.
- Every asset and API route requires admitted source, exact host, and Basic
  credentials.
- Mutations reject missing/wrong Origin, missing `X-Pizarra`, wrong media type,
  unknown or duplicate keys, wrong types, query parameters, and bodies over
  64 KiB.
- CORS preflight is rejected and security headers are present on success and
  error responses.
- SSE resume, message direction, keepalive, gap, and terminal events match the
  documented contract.
- Browser operations distinguish `not_sent`, `unknown`, and `applied_stale`.
- The Activity tab remains bounded while durable History still pages older
  messages.

### Backup, restore, and update

- A backup is published only after all pieces and the manifest are complete.
- A configured external shared/NFS sentinel is absent from the backup payload;
  only the `[shared] dir` reference inside the included hub config remains.
- Verification detects a missing, changed, duplicated, or unlisted piece,
  missing secret, invalid SQLite integrity/foreign keys, and undeclared
  SQLite WAL/shared-memory payload.
- Restore dry-run changes nothing and prints the exact target.
- Restore refuses a running/locked hub, a missing or unsafe persistent lock,
  unconfirmed execution, and an unaccepted credential mismatch.
- Restore moves previous state aside and does not retain stale SQLite sidecars.
- A privileged restore preserves the live configuration/store owners so a
  dedicated-account hub can reopen every mode-`0600` replacement.
- The restored hub exposes the expected registries, tasks, workflows, cursors,
  and messages.
- Restore leaves external shared/NFS content unchanged; the restored hub
  reference and pzweb `[web] shared` are rechecked for exact equality before
  service startup.
- Layout migration preserves hub `[shared] dir` and pzweb `[web] shared`
  literally, never traverses the mounted tree, and retirement leaves an
  external sentinel unchanged.
- Release-layout migration preserves the selected tree exactly, leaves its
  source untouched, rewrites `[server] releases` to
  `/var/lib/pizarra/releases`, and aborts before installation on conflicting
  non-empty trees.
- A relative legacy release path is rejected unless the operator supplies its
  reviewed absolute source with `--source-releases`.
- Repository-runtime retirement requires that exact canonical, real, private,
  outside-repository release directory and rejects symlinks and special entries.
- A release is not advertised until `VERSION` exists and matches the running
  hub.
- Publication accepts only an absolute `RELEASEDIR`, stages artifacts under
  temporary names, and renames `VERSION` last.
- Endpoint installation rejects a wrong digest, wrong version, oversized
  artifact, or incomplete download; a failed post-install self-test restores
  the previous executable, while verified success prunes rollback copies.

## Concurrency and failure injection

The highest-value failures occur between durable truth and its projection. Test
at least these interruption points:

- after journal append but before endpoint acknowledgement;
- after workflow commit but before linked-task update or notification delivery;
- while several watchers consume replay and live traffic;
- during simultaneous inbox pagination and acknowledgement;
- during parallel uploads using separate transfer IDs;
- after staging an update but before atomic replacement; and
- after moving live files aside but before a restore finishes.

After each interruption, restart the affected process and verify that the
system either completes reconciliation or reports a precise degraded/unknown
outcome. A test must never infer rollback solely from a lost network response.

## Documentation and release review

Before a public release:

1. run `make test` from a clean checkout;
2. exercise the relevant integration matrix on isolated state;
3. check that all sample secrets and addresses are placeholders;
4. scan tracked files for private paths, credentials, generated state, binaries,
   caches, and tool-specific development artifacts;
5. verify every Markdown link and referenced screenshot exists;
6. compare CLI help, configuration examples, API routes, and protocol docs with
   source;
7. inspect the exact staged diff and `git ls-files` output; and
8. create release artifacts only from the committed tree.

## Tag, GitHub release, and wiki publication

Version choice is a release decision, not a documentation-only edit. Before
tagging, prove that `src/pzver.pas`, all three `--version` outputs, the
changelog heading, release notes, README, and every version-bearing wiki page
name the same release. Do not reuse the currently deployed version for changed
binaries, and do not publish a numerically older tag over a newer public
branch.

The project wiki is a separate Git repository from the source repository. Treat
its commit and push as a distinct publication step: update it from the same
source commit, inspect its own diff/status, and do not let a successful source
push imply that the wiki was updated.

For a release `<version>`:

1. freeze the source and version-bearing documentation;
2. run the complete build and focused bootstrap, private-config, shared-copy,
   group-policy, release-layout migration, and retirement tests, plus the
   relevant isolated integration matrix;
3. verify Markdown links, screenshots, tracked-file inventory, and both source
   and wiki diffs;
4. commit and push the tested source commit;
5. create an annotated `v<version>` tag on that exact commit and push it;
6. create the GitHub Release from that tag with notes matching the changelog;
7. commit and push the separately reviewed wiki update; and
8. verify the public tag, release assets/notes, source pages, and wiki after
   publication.

`make publish` serves the fleet's `tiza` self-update artifacts and is not the
GitHub Release operation. It deliberately requires a clean committed tree;
both publication channels must refer to the same chosen suite version.

For the first GitHub publication, the fixed release tuple is suite `1.1.22`,
annotated tag `v1.1.22`, and GitHub Release title **Pizarra 1.1**. This continues
the deployed 1.1 line after 1.1.21; the discarded, untagged development
placeholder is not a release and must never be presented as one.

When reporting a test result, include the suite version, operating system,
architecture, Free Pascal version, SQLite availability, topology, exact command,
expected result, actual result, and whether a retry was attempted.
