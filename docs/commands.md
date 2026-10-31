# Commands

Run from a project's folder, the one with `config/deploy.yml`. Every command takes
`-c, --config <path>` for another config file. A failure exits with 1, a command not
understood with 2.

## Preparing

**`cowshed check [--secrets <path>] [--remote]`** reads the config and the secrets'
names, without running any secret's command. `--remote` also reaches the server and
Docker. Changes nothing.

**`cowshed setup [--dry-run]`** prepares a server, and is safe to run again: Docker if
missing (needs root or sudo without a password), `~/.cowshed`, and Traefik if none
runs. It uses a Traefik already there and changes nothing that exists. It stops, saying
why, at anything that would touch other apps. `--dry-run` says what it would do.

## Deploying

**`cowshed deploy [--secrets <path>] [--dirty] [--force]`** builds the image on this
machine, sends what the server lacks, starts the new version beside the old one, checks
its health, moves the traffic, waits for the old one's connections and stops it. Until
the traffic moves, any failure leaves the old version untouched.

- `--dirty` ships this folder as it is, as a test. Without it, uncommitted work stops
  the deploy; with `branch` or `sources` it is left out instead.
- `--force` deploys even if nothing changed.

**`cowshed rollback <version>`** goes back to a version still on the server, with no
build. If it fails its health it is stopped again, and what is live stays live.

## Looking

**`cowshed versions`** lists what is on the server, what is live, and what each was made
from.

**`cowshed logs [--lines <n>]`** shows the live container's latest logs (100 by default).

**`cowshed audit`** shows who deployed what and when.

**`cowshed exec [--version <v>] <command...>`** runs a new container of a version, the
live one's by default, with the live one's variables and network, and removes it after.
Its exit code decides the result. Its output comes when it ends.

## Maintaining

**`cowshed prune`** removes what no kept version uses. A deploy does this too; the last
3 stopped containers stay for a rollback.

**`cowshed stop`** removes the route and stops what runs. The containers stay, and a
`rollback` brings one back.

**`cowshed remove [--yes]`** removes the app from the server for good: route, containers,
images and their files. Without `--yes` it only lists them. The audit log and a container
named in `replaces` stay.

**`cowshed lock status`**, **`cowshed lock release`** say who holds the deploy lock and
free it after a deploy that died.
