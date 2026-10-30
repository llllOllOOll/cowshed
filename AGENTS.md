# Cowshed: agent guide

Cowshed deploys Docker containers to a server over SSH, as one Zig 0.17 binary.
README.md is the overview, `docs/design.md` the design, BACKLOG.md the plan.

## Commands

```bash
zig build            # Build
zig build test       # Unit tests
scripts/check.sh     # Format, tests and the architecture rules
tests/setup_e2e.sh   # setup over real SSH on a throwaway server (needs Docker)
tests/deploy_e2e.sh  # deploy the same way, under traffic, with its failures
```

## Architecture: ports and adapters

```
src/
├── main.zig      # Entry point
├── cli/          # Reads arguments; a file per command, `ops.zig` for those on a deployed app
├── config/       # YAML, validation, secrets
├── deploy/       # The core: the steps of deploy, rollback and prune
├── docker/       # Builds Docker commands, runs nothing
├── proxy/        # Detects Traefik, renders and validates routes
├── image/        # Builds images and sends them
└── remote/       # The port to the server: real (ssh) and fake (tests)
tests/            # Integration against real Docker and Traefik
```

Folders appear with their first file; this tree is the target.

**The rules** (`scripts/check.sh` checks them):
- `deploy/` never reaches the outside directly. It asks the `remote` port, so its
  whole flow, failures included, is tested with no server.
- Only `remote/` and `image/` start processes.

## What must hold in every change

- **The old version keeps serving until the new one is proven.** Every failure
  path leaves it untouched.
- **Secrets never reach a command line, a log or a config dump.**
- **Arguments stay whole over SSH:** each remote word is quoted on its own.
- **Never compile on a production server.** It only packages or loads images.
- **Touch only what Cowshed owns on a server.** Other apps' routes, containers
  and Traefik's own settings are not ours; a change that restarts Traefik needs
  the owner's explicit yes.
- **An unknown config option is refused by name,** not ignored.

## Keeping the docs true

In the same commit as a change: this file and `docs/` when a command, rule or
behaviour changes, README.md when what a user sees changes, BACKLOG.md for what
landed and what was found.

## Code style

Comments and docs in English. `camelCase` functions, `PascalCase` types,
`snake_case` variables, `SCREAMING_SNAKE_CASE` constants. A file that is a struct
is `PascalCase.zig`, any other `snake_case.zig`. Tests at the end of a file; those
needing real Docker in `tests/`.
