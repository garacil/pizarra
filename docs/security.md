# Security model

pizarra coordinates processes that can edit code, execute commands, and operate
terminal sessions. Its security boundary therefore includes the network, hub
credentials, configuration and backup files, operating-system accounts,
terminal multiplexers, launch commands, shared files, and the content sent to
agents.

The suite is intended for a trusted private network. It is not an Internet-edge
service.

## Threat model

The implementation is designed to resist:

- an unauthenticated client attempting to read or mutate hub state;
- a team credential claiming another identity;
- a delegated service using command families it was not granted;
- malformed, oversized, duplicated, or ambiguous JSON input;
- a browser cross-origin mutation or unapproved source address;
- path traversal, symlink following, and partial publication in shared files;
- a slow or stalled network peer consuming unbounded resources;
- a lost acknowledgement producing silent message loss;
- a corrupt or incomplete transfer being installed or published; and
- accidental restore into a live or unintended store.

It does not make these adversaries safe:

- an attacker that has obtained the master credential;
- an attacker that controls the hub process or its operating-system account;
- a malicious team process running under the same account as another team's
  terminal session;
- untrusted content interpreted as instructions by an autonomous agent;
- an observer on the cleartext native or HTTP network path; or
- an operator-authorized `launch`, update, recursive deletion, or restore that
  is itself unsafe.

## Credential model

The hub has one master credential and one unique credential per configured
team. A team credential is bound to that team: it cannot select a different
`from` identity. Administrative authority is added by explicit command-family
delegation.

```text
team group project app task workflow watch backup update header
```

Treat these as capabilities, not cosmetic roles. In particular:

- `watch` can expose wider message traffic;
- `backup` can create a credential-bearing hub backup set;
- `update` can replace and restart endpoint executables;
- `header` changes standing context delivered to the fleet;
- registry and workflow families can redirect authority or work.

Set `master_console_only = on` after every non-console identity uses its own
credential. The hub rejects empty team credentials, duplicate team credentials,
and any team credential equal to the master credential.

Direct-push delivery is a deliberate exception at the daemon boundary: the hub
currently authenticates a pushed `deliver` request with the master credential,
so the remote daemon must hold it. Do not copy that credential into a team slot,
and do not use direct push where a bound reverse-dial credential is sufficient.
A compromised direct-push host can expose the master credential.

## Transport boundary

The native hub and daemon protocols authenticate with shared secrets but do not
encrypt traffic. The web server uses cleartext HTTP Basic authentication and
does not implement TLS. Anyone able to observe the network path can recover
credentials and message content.

Recommended controls:

- bind to loopback or an explicit private address, never a wildcard by habit;
- firewall the hub, daemon, and web ports to exact peers;
- prefer reverse dial so remote hosts need no inbound daemon port;
- use a private encrypted network or a local tunnel when traffic crosses a
  physical or administrative boundary;
- never expose a native or web listener directly to the public Internet; and
- validate the complete browser mutation flow before introducing an HTTP proxy,
  because the current web origin model is exact and not proxy-aware.

Authentication without confidential transport is not sufficient protection.

## Configuration-file boundary

All typed hub, client, daemon, and web loaders parse a selected
credential-bearing INI from one descriptor held for the complete read. The
final file must be regular with mode exactly `0600`; symbolic links in any path
component and group/other-writable ancestors are rejected, except for a
root-owned sticky directory such as `/tmp`. Comparing the pre-open path metadata
with the opened descriptor and then parsing only that descriptor prevents a
pathname replacement from redirecting the read. Quoted INI values are stripped
consistently across loaders.

## Web safeguards

`pzweb` fails startup unless its security contract is complete:

- the config is a regular, non-symlinked file with mode exactly `0600`;
- the listener is a non-wildcard IPv4 address;
- `allow_from` contains valid exact IPv4/CIDR rules;
- the expected `Host` and exact `http://` origin agree;
- Basic username and SHA-256 password digest are configured;
- static and optional shared paths exist without symlink components;
- its hub credential is bound, cannot act as `console`, and holds all required
  delegated families.

Every request is checked for source address, exact `Host`, and Basic
credentials. Mutations additionally require an exact `Origin`, JSON media type,
`X-Pizarra: 1`, a body no larger than 64 KiB, no query parameters, and an exact
route-specific object shape. Duplicate and unknown keys are rejected. The
server does not grant CORS access and rejects `OPTIONS`.

Static assets are loaded into memory at startup, capped per file and in total,
and served with content-derived ETags. Responses set a same-origin Content
Security Policy, deny framing, disable MIME sniffing, and suppress referrer
leakage. Connection, per-peer, and SSE limits bound resource use.

The Basic password is stored as an unsalted SHA-256 digest. This avoids storing
the clear password but is not a password-hardening scheme. Use a long,
high-entropy, unique password and protect the configuration as the effective
credential.

## Input and protocol validation

The native protocol caps each JSON line at 1 MiB. Parsers validate commands,
types, names, state transitions, identities, and authority before mutation.
Names use a restricted character set. Transfers and HTTP bodies have lower
feature-specific caps.

Consumers distinguish rejection, safe-to-retry failure, and unknown outcome.
This is a security property as well as a reliability property: repeating an
unconfirmed mutation can duplicate privileged actions.

Live streams use explicit `gap` events when continuity cannot be guaranteed.
Clients must rebuild from durable state instead of filling missing data by
assumption.

## Terminal sessions and launch commands

The hub and endpoint daemon can create a configured terminal session and paste
messages into it. A `launch` value is executed by a shell. It is executable code
even when set through an authenticated API.

- Restrict registry mutation authority.
- Review launch commands as carefully as service-unit commands.
- Use a dedicated account per trust domain; Unix permissions cannot isolate
  teams that deliberately share one account and terminal server.
- Give the service account only the filesystem and process access its sessions
  require.
- Keep session names, working directories, and usernames fixed and validated.
- Never place untrusted message content into a launch value.

Delivery uses a named terminal buffer, bracketed paste, and one explicit Enter,
which preserves multiline input. It does not make message content trustworthy.
An autonomous receiver still needs its own instruction/data boundary and
least-privilege execution environment.

Activity sampling reads terminal output and classifies it using heuristics or an
optional explicit hint file. It is disabled by default. `auto_enter` can accept
the terminal's highlighted default and is therefore disabled by default; enable
it only for a fully understood and isolated session.

## Shared files and transfers

The optional shared exchange is operational coordination space, not a secure
content scanner. Per-team directories are intentionally writable for exchange
and may use sticky-directory semantics.

Treat it as a separate mounted data domain. Hub `[shared] dir` and pzweb
`[web] shared` must name the same reviewed absolute mount; do not relocate it
under `/var/lib/pizarra` during consolidation. Store no credentials, live
configuration, backup bundle, or release authority in this tree. Migration and
repository retirement preserve the configuration references but do not copy,
move, archive, or remove external shared data. The built-in backup contains the
hub configuration reference only, and restore never restores shared content;
use a coordinated external snapshot when recovery requires it.

Safeguards include:

- restricted basenames and exact directory levels;
- no path separators, dot segments, or NUL bytes in public file selectors;
- descriptor-anchored, no-follow browser operations;
- local/NFS sharing reserves a mode-`0600` regular temporary inode with
  `O_CREAT|O_EXCL` and, on Linux, `O_NOFOLLOW` before copying, then publishes it
  mode `0644` only after completion; a preplanted symlink is never followed or
  removed;
- no overwrite on name collision;
- private temporary staging followed by atomic link or rename publication;
- exact upload offsets and whole-file SHA-256 verification;
- 512 KiB native chunks and a 10 MiB transferred-file cap; and
- explicit recursive deletion with partial-outcome reporting.

SHA-256 protects transfer integrity, not trust in the sender. Do not execute a
shared artifact merely because its digest matches. The digest proves only that
the bytes received are the bytes the authenticated sender declared.

## Persistence, logs, and backups

The journal, configuration, task text, workflow evidence, application manuals,
and logs may all contain sensitive data. Protect those private state files and
backups with owner-only permissions and encrypted storage where the host threat
model requires it. The shared exchange is intentionally different: the hub
uses sticky writable team directories and publishes exchange files for peer
access. Control that external mount at the NFS/export, network, host-account,
and directory boundaries, and do not put secrets there.

Backups include the hub configuration and credentials by design. They are
assembled privately and published atomically with a digest manifest, but the
result is still equivalent to a live credential bundle. Never store it in the
repository, web static tree, or shared exchange.

Restore verifies the manifest, refuses a live hub, displays the exact target,
requires confirmation, preserves previous state, removes stale SQLite sidecar
risk, and separately warns about credential rollback. These checks do not
replace offline access control or operator review.

## Updates

The hub serves only locally published release artifacts whose stamped version
matches its own. Endpoint downloads carry an expected size and SHA-256 digest.
The daemon tests a staged candidate, creates a rollback copy, installs
atomically, tests the installed binary, and restores the copy if that final gate
fails. Rollback copies are removed after verified success.

This protects against truncation and accidental artifact mismatch. It is not a
public-key software-signing system: a party that controls the hub, release
directory, or update capability remains trusted. Keep automatic updates off
where independent release approval is required.

## Deployment checklist

- [ ] Every placeholder secret has been replaced with a unique, high-entropy
  value.
- [ ] Master and team credentials are distinct; every team credential is
  unique.
- [ ] Direct push is absent, or each host holding the master credential is an
  accepted and documented trust exception.
- [ ] `master_console_only = on` is enabled after credential migration.
- [ ] Config files and daemon receipt state are owner-only and outside Git.
- [ ] Hub, daemon, and web listeners are explicitly bound and firewalled.
- [ ] Traffic is loopback-only or protected by an independent encrypted
  network boundary.
- [ ] Web `allow_from`, `host`, `origin`, and Basic credentials are exact.
- [ ] Delegated families are minimal and reviewed.
- [ ] Service accounts and launch commands have been reviewed.
- [ ] Activity sampling and `auto_enter` are opt-in decisions.
- [ ] Shared files cannot escape their intended filesystem boundary.
- [ ] A secret-bearing backup has been verified and restore-tested in isolation.
- [ ] Update artifacts and release-directory write access are controlled.
- [ ] Operators know how to handle unknown outcomes and live-stream gaps.

For vulnerability reporting, see the repository [security policy](../SECURITY.md).
