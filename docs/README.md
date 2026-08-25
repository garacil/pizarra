# pizarra documentation

This documentation describes the public `pizarra` suite as implemented by the
source tree: the `pizarra` hub, the `tiza` client/console/host daemon, and the
`pzweb` browser console.

The installed layout is centralized under `/etc/pizarra`, `/var/lib/pizarra`,
and `/var/log/pizarra`. `org.sqlite` is the sole live organization registry;
`pzweb` reaches it only through authenticated hub commands. See
[Configuration](configuration.md) for authority and paths and
[Operations](operations.md#consolidating-an-existing-checkout-based-installation)
for lossless cutover from an older checkout-based deployment.

## Start here

| Document | Purpose |
|---|---|
| [Architecture](architecture.md) | Components, trust boundaries, state, delivery, and concurrency |
| [Quick start](quickstart.md) | Build and run a safe local installation |
| [Configuration](configuration.md) | Hub, endpoint daemon, and web configuration keys |
| [CLI](cli.md) | `pizarra` and `tiza` command reference |
| [Web console](web-console.md) | Browser views, behavior, and deployment requirements |
| [Web API](web-api.md) | HTTP contract, route families, request rules, and outcomes |
| [Wire protocol](wire-protocol.md) | Native newline-delimited JSON protocol |
| [Workflows](workflows.md) | Dependency graphs, tasks, errors, verification, and history |
| [Operations](operations.md) | Deployment, supervision, backup, recovery, and fleet updates |
| [Security](security.md) | Threat model and implementation safeguards |
| [Testing](testing.md) | Build checks and an integration test matrix |
| [Limitations](limitations.md) | Current scope and deliberate constraints |

Repository-level policies:

- [Security policy](../SECURITY.md)
- [Contribution policy](../CONTRIBUTING.md)
- [License](../LICENSE) (`GPL-3.0-only`)
- [Sole-author record](../AUTHORS)
- [Changelog](../CHANGELOG.md)

## Terminology

- **Hub**: the `pizarra` process and its durable coordination state.
- **Team**: an addressable agent identity with a role and delivery target.
- **Endpoint**: a `tiza` identity used from a shell, an agent session, or the
  human console.
- **Host daemon**: `tiza daemon`, which receives remote deliveries and injects
  them into local terminal sessions.
- **Console**: the privileged human identity, normally named `console`.
- **Group**: a named set of teams used for broadcast and workflow membership.
- **Project**: an organizational label with an optional administrator.
- **Application**: a registered software component with one responsible team.
- **Task**: durable work assigned to a team or left in the backlog.
- **Workflow**: a dependency graph of milestones projected into tasks.
- **Delivery**: transfer of a wrapped message into a team's terminal session.
- **Inbox**: a cursor-based durable view of messages addressed to an identity.

## Documentation guarantees

Examples use placeholders and loopback addresses unless they explicitly
illustrate a private-network topology. They contain no operational credentials
or deployment-specific paths. Features marked optional require explicit
configuration; absence of an optional component never implies that it is
enabled.
