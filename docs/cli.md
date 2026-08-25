# Command-line reference

`pizarra` runs the hub. `tiza` provides every native client role: one-shot
commands, the interactive human console, and the remote host daemon.

Examples below assume `TIZA_CONF` points to the intended identity. In services
and scripts, prefer `--config /absolute/path`.

## `pizarra`

```text
pizarra [--config PATH] [--version]
```

| Command | Effect |
|---|---|
| `pizarra --config PATH` | Run the hub with an explicit INI file |
| `pizarra --version` | Print suite version and SQLite availability |
| `pizarra --help` | Print the compact usage line |

The hub remains in the foreground and handles SIGINT/SIGTERM cleanly.

## `tiza` global behavior

```text
tiza [--config PATH] <command-or-destination> ...
```

- Identity always comes from `[pizarra] self` in the selected configuration.
- A normal `--from` is ignored; use the correct identity file.
- `TIZA_CONF` selects the configuration when `--config` is absent.
- `--version`, `--help`, `manual`, and workflow help operate without a hub.
- Human-readable tables are used on a terminal; redirected output is plain.
- A command that reaches the hub is still subject to its identity and authority
  checks.

## Messaging and inbox

| Command | Meaning |
|---|---|
| `tiza <team> <message...>` | Send to a team by name or numeric ID |
| `tiza all <message...>` | Send one durable copy to every other team |
| `tiza @<group> <message...>` | Send to all non-excluded group members |
| `tiza <group> <message...>` | Bare group name; a team wins a name collision |
| `tiza <dest> --file PATH` | Use a file as a multiline body; `-` reads stdin |
| `tiza inbox` | Show unread messages and advance through returned entries |
| `tiza inbox --keep` | Peek without advancing the cursor |
| `tiza inbox --all` | Show history rather than only unread entries |

Message files are capped at 256 KiB. The native line frame is capped at 1 MiB.
When a destination is temporarily unavailable, a successful send reports
`queued`; retry is automatic.

## Human terminal console

```sh
tiza chat
tiza chat --plain
```

Normal mode provides a live bus feed, colors, line editing, UTF-8-aware
backspace, cursor movement, persistent Up/Down history, and redraw-safe incoming
events. `--plain` is suitable for limited terminals or redirected input.

Sending:

```text
builder: short message
@release: message to the group
/send builder short message
/msg builder
first line
second line
.
/file builder /path/to/message.txt
```

In compose mode, a line containing only `.` sends and `/cancel` aborts.

Principal console commands:

| Command | Meaning |
|---|---|
| `/teams` | Refresh team index |
| `/tree` | Show hierarchy |
| `/inbox` | Read the console inbox |
| `/log [n]` | Show recent bus history |
| `/full <seq>` | Expand a message cached in this console session |
| `/task ...` | Task commands |
| `/wf ...` | Workflow commands |
| `/team ...` | Team registry |
| `/group ...` | Group registry |
| `/project ...` | Project registry |
| `/app ...` | Application registry and manuals |
| `/header ...` | Delivery-header settings |
| `/share ...`, `/files ...`, `/cat ...` | Shared-file operations |
| `/fleet`, `/update ...` | Fleet status and update |
| `/clear`, `/quit` | Clear or exit |
| `/help [topic]` | Embedded task-oriented manual |

The watch stream reconnects from its last processed sequence. The console sends
batched acknowledgements only after events have been rendered.

## Tasks

```text
tiza task add <team|-> <title...> [--milestone LABEL] [--parent ID]
tiza task done <id>
tiza task reopen <id>
tiza task delete <id>
tiza task note <id> <text...>
tiza task assign <id> <team|->
tiza task list [open|done|all|STATE] [team|@group]
tiza task show <id>
```

`-` means backlog/unassigned. Task states are open strings; `done`,
`superseded`, and `cancelled` are terminal in the current engine. A workflow
may gate state and assignment changes for linked tasks.

Deleting a task is refused when it is linked to a workflow or has subtasks.
Notes are append-only, attributed, and timestamped.

## Workflows

`wf` and `workflow` are equivalent:

```text
tiza wf create <name> <group>
tiza wf step <name> <team> <milestone...> [--after K[,K...]|0] [--eta 4h]
tiza wf start <name>
tiza wf done <name> [step|-] ["how tested..."]
tiza wf error <name> <why...> [--step N]
tiza wf fixed <name> <what-fixed-and-how-tested...>
tiza wf verify <name> ok|fail [note...]
tiza wf show <name> [--from K] [--depth N] [--detail]
tiza wf tasks <name>
tiza wf list [--mine] [--team TEAM]
```

Draft editing and history:

```text
tiza wf insert <name> <team> <milestone...> --after K [--eta 4h]
tiza wf remove <name> <step>
tiza wf set <name> <step> team|milestone|after|eta <value...>
tiza wf set <name> eta <duration|off|factory>
tiza wf set <name> strict on|off
tiza wf clone <source> <new-name> [group]
tiza wf history <name>
tiza wf undo <name> [snapshot]
tiza wf save <name> [file.wf.json]
tiza wf restore <name> <file.wf.json>
tiza wf export <name> [file.sqlite|file.sql|file.mmd|file.dot]
tiza wf abort <name> [why...]
tiza wf delete <name> [why...]
```

`--after 0` makes a root. Multiple dependencies form a join. A dependency may
also reference another workflow as `other-workflow#3`. See
[Workflows](workflows.md) for authority and lifecycle rules.

## Teams and hierarchy

```text
tiza team list
tiza team show <name> [--detail]
tiza team add <name> <speciality...> [--parent TEAM]
              [--remote HOST[:PORT]] [--session NAME|-]
              [--launch COMMAND] [--prompt TEXT]
tiza team set <name> <field> <value...>
tiza team remove <name>
tiza tree
```

Settable fields are `prompt`, `speciality`, `parent`, `launch`, `session`,
`user`, `project`, `slave`, and `workdir`. A host address is selected at team
creation/configuration time and is not mutable through `team set`.

Removing a team does not kill its terminal session and does not erase its task
history. Referential and open-work checks may refuse removal.

## Groups and projects

```text
tiza group list [name]
tiza group show <name>
tiza group add <name> <team...>
tiza group remove <name> [team...]
tiza group boss <name> <team>
tiza group project <name> <project>
tiza group exclude <name> [team...]
tiza group onidle <name> off|boss|all|team[,team]
tiza group onidlemsg <name> [text...]
tiza group onidlefrom <name> [identity]
tiza group onidlereply <name> [identity]
tiza group header <name> [standing instruction...]
```

`group remove <name>` deletes the group; adding team arguments removes only
those members. `exclude` replaces the complete muted set; no members clears it.

```text
tiza project list
tiza project show <name>
tiza project boss <name> <team>
tiza project remove <name>
```

Assigning a boss to a new name creates the project. Removal is refused while
teams or groups still refer to it.

## Applications

```text
tiza app list [team]
tiza app show <name>
tiza app add <name> --team TEAM [--repo URL] [--path PATH]
             [--purpose TEXT] [--detail TEXT]
tiza app set <name> team|repo|path|purpose|detail <value...>
tiza app remove <name>
tiza app doc <name>
tiza app doc <name> --file FILE
tiza app doc <name> --at <snapshot>
tiza app history <name>
tiza app undo <name> <snapshot>
tiza app project <name> <project> [--role TEXT]
tiza app unproject <name> <project>
```

Each application has one responsible team but may participate in several
projects, with a different role in each. Manuals and changes are historized.

## Delivery-header configuration

```text
tiza header show
tiza header short
tiza header full
tiza header set <key> <value>
tiza header note [standing instruction...]
```

Supported keys match the `[header]` configuration described in
[Configuration](configuration.md). These commands affect context delivered to
the whole fleet and require appropriate authority.

## Shared files

```text
tiza share <team|console> <file> [note...]
tiza files [team|console]
tiza put [<dest>] <file> [note...]
tiza get <shared-path> [local-file]
tiza cat <shared-path>
```

- `share` copies through a locally mounted shared directory.
- `put` uploads over the bus for a host without that mount.
- `get` and `cat` retrieve over the bus.
- Transfers are limited to 10 MiB, chunked under the wire cap, and verified by
  SHA-256 before final publication.
- Destination basenames begin with an alphanumeric character and otherwise use
  only letters, digits, dot, underscore, and hyphen.
- Collisions produce `.2`, `.3`, and later names; existing files are not
  overwritten.

## Activity and delivery holds

```text
tiza hold <team> on|off
tiza fleet
tiza ver
```

Activity sampling is configured per host-daemon session. A reliable blocked
report may auto-hold a team when `hold_when_blocked` is enabled; heuristic
reports alarm but do not automatically hold. Manual holds keep messages pending
until released.

## Backup, restore, and updates

```text
tiza backup [directory] [--force]
tiza backup verify <directory>
tiza restore <directory> --dry-run
tiza restore <directory> --confirm [--force]
tiza update <team|all> [--force]
```

Backups contain credentials. Verification is local. Restore requires the hub to
be stopped and discovers its target configuration explicitly; use a dry run
first. Update installs the release published by the hub, not an arbitrary
version supplied by the caller.

See [Operations](operations.md) before using these commands.

## Local manual and version

```text
tiza --help
tiza manual
tiza wf help
tiza --version
tiza ver
```

`--version` reports only the local binary. `ver` also queries the hub when a
configuration is available.
