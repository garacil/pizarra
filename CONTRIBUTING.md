# Contributing

pizarra is currently authored and maintained solely by **Germán Luis Aracil
Boned <garacilb@gmail.com>**. Bug reports, reproducible test cases, design
feedback, and documentation observations are welcome through the repository
issue tracker.

External code and documentation patches are not accepted at this initial
public stage. To preserve the stated sole-authorship record, do not open a pull
request or attach copyrighted replacement text. Describe the problem and a
minimal reproduction; the maintainer will independently implement any change.

## Public-repository rules

Everything submitted must be safe to publish and written in English.

Never include:

- real secrets, password digests, tokens, certificates, or private keys;
- production hostnames, addresses, paths, usernames, session names, or logs;
- message journals, task/workflow state, databases, backups, or shared files;
- screenshots or fixtures derived from operational data;
- private planning documents, internal audits, or development provenance;
- vendor- or tool-specific agent integrations, configuration, metadata, or
  generated attribution; or
- unrelated applications or services outside `pizarra`, `tiza`, and `pzweb`.

Use synthetic identities such as `planner`, `builder`, and `reviewer`, loopback
addresses, placeholder secrets, and disposable temporary stores. Do not add
author, co-author, maintainer, or generated-by metadata. The repository's public
authorship record is managed by the maintainer.

If a report accidentally contains sensitive data, stop adding details and use
the private process in [SECURITY.md](SECURITY.md).

## Before reporting a change request

1. Read the [architecture](docs/architecture.md),
   [wire protocol](docs/wire-protocol.md), and
   [security model](docs/security.md).
2. State the user-visible problem, trust boundary, and compatibility impact.
3. For protocol or persistence changes, describe crash/retry behavior and how
   older peers or state files behave.
4. For workflow changes, preserve stable step IDs, cycle checks, authority,
   snapshots, linked-task reconciliation, and error verification.
5. For web changes, preserve strict route schemas, Host/Origin checks, no-CORS
   behavior, security headers, bounds, and accessible keyboard operation.

Avoid adding an external dependency when the existing standard library or a
small local implementation is sufficient. New runtime dependencies need an
explicit operational and security rationale.

## Build and verify locally

```sh
./configure
make check
make test
```

Compiler warnings are errors. For changes that can benefit from runtime checks:

```sh
make debug
```

`make test` currently builds all three programs and checks their version entry
points. It is not a substitute for relevant integration coverage. Follow the
matrix in [Testing](docs/testing.md) using loopback listeners, disposable
credentials, and a temporary store.

Before describing or privately evaluating a change:

- inspect the exact diff and tracked-file list;
- confirm no private or generated files were added;
- run the affected CLI and browser paths;
- test rejected and unknown outcomes, not only success;
- update public documentation and examples in the same change; and
- do not create release artifacts from an uncommitted tree.

## Source and documentation style

- Follow the existing Free Pascal mode, naming, locking, and ownership patterns.
- Keep blocking network work and notifications outside store locks.
- Commit durable truth before external projection; make reconciliation explicit.
- Reject unknown input instead of guessing.
- Preserve bounded memory, input, connection, and transfer behavior.
- Keep user-facing text, comments, examples, and documentation in English.
- Describe implementation behavior precisely; do not claim encryption,
  exactly-once execution, high availability, or test coverage that is absent.
- Keep the suite vendor-neutral.

The maintainer owns version selection and release publication. A wire-breaking
change requires an explicit compatibility design, not only a version bump.

## Licensing and contributions

The published repository is GNU General Public License, version 3
(`GPL-3.0-only`), but that license does not change the current contribution
policy: external code and documentation patches are not accepted. If the
project opens copyrighted contributions later, it will publish the applicable
authorship and rights terms first.
