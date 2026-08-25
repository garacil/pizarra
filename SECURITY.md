# Security policy

## Supported versions

Security fixes are made against the latest public release. Older releases may
be used to reproduce a report, but users should expect to upgrade to receive a
fix.

| Version | Security support |
|---|---|
| Latest public release | Supported |
| Earlier releases | Not supported |

## Report a vulnerability

Do not open a public issue for a suspected vulnerability. Email
**Germán Luis Aracil Boned <garacilb@gmail.com>** with the subject
`[pizarra security]`.

Include, where possible:

- affected component and version;
- deployment topology and relevant non-secret configuration;
- prerequisite access or credential level;
- reproducible steps or a minimal proof of concept;
- observed and expected behavior;
- impact on confidentiality, integrity, or availability; and
- any suggested mitigation.

Never send live credentials, private message content, production backups, or
unredacted logs. Replace them with minimal synthetic values. If sensitive
material is essential to reproduce the issue, first ask how to transfer it.

Reports are handled on a best-effort basis. The author will validate the issue,
agree on a disclosure plan when appropriate, prepare a fix, and credit the
reporter only if the reporter explicitly requests public credit. This project
does not currently operate a bug-bounty program.

## Scope

Security reports are especially useful for:

- authentication or identity-binding bypass;
- delegated-authority bypass;
- cross-team message or state disclosure;
- web source, Host, Origin, or mutation-guard bypass;
- path traversal, symlink following, or unintended file overwrite/deletion;
- command injection outside explicitly trusted `launch` configuration;
- transfer/update acceptance without required integrity verification;
- restore or backup behavior that exposes or corrupts protected state;
- remotely triggerable denial of service beyond documented resource limits;
  and
- secrets or private operational data committed to the public repository.

Documented architectural constraints—such as cleartext private-network
transport, symmetric credentials, one web user, and direct push holding the hub
master credential—are described in [the security model](docs/security.md) and
[limitations](docs/limitations.md). A way to bypass their documented boundary
or worsen their impact is still in scope.

## Operator responsibility

Before deployment, follow [the security checklist](docs/security.md), keep real
configuration and state outside version control, use unique credentials, prefer
reverse dial over direct push, restrict listeners to a trusted private network,
and protect backups as credential bundles.

Copyright © 2026 Germán Luis Aracil Boned. Licensed under
[`GPL-3.0-only`](LICENSE).
