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

`make static` intentionally fails because the threaded programs use the system
C runtime and load SQLite dynamically. Do not treat that failure as a test
regression.

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

- Team parent cycles and missing references are rejected.
- Project and group administrators have only documented authority.
- Removing an object still referenced by open work or relations is refused.
- Application ownership, project roles, manuals, history, and undo survive a
  hub restart.
- When SQLite is unavailable, registry writes fail visibly while messaging,
  tasks, and workflows remain available.

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
- Verification detects a missing or changed piece, missing secret, and invalid
  SQLite header.
- Restore dry-run changes nothing and prints the exact target.
- Restore refuses a running hub, unconfirmed execution, and an unaccepted
  credential mismatch.
- Restore moves previous state aside and does not retain stale SQLite sidecars.
- The restored hub exposes the expected registries, tasks, workflows, cursors,
  and messages.
- A release is not advertised until `VERSION` exists and matches the running
  hub.
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

When reporting a test result, include the suite version, operating system,
architecture, Free Pascal version, SQLite availability, topology, exact command,
expected result, actual result, and whether a retry was attempted.
