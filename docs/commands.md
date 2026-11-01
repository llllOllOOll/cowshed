# Commands

Run from a project's folder, the one with `config/deploy.yml`. Every command takes
`-c, --config <path>` for another config file. A failure exits with 1, a command not
understood with 2.

## Preparing

**`cowshed init [--host <server>] [--domain <name>]`** starts a project with nothing of
Cowshed's: `config/deploy.yml`, `.cowshed/secrets`, and the secrets kept out of git in
`.gitignore`. The service comes from the folder's name and the port from the Dockerfile's
`EXPOSE`; what it cannot know it says to fill in. It reaches no server. If
`config/deploy.yml` exists it changes nothing; existing secrets are kept.

**`cowshed check [--secrets <path>] [--remote]`** reads the config and the secrets'
names, without running any secret's command. `--remote` also reaches the server and
Docker. Changes nothing.

`setup` and `proxy adopt` keep a copy of what they say on this machine, in
`~/.local/state/cowshed/logs/`, and name the file at the end.

**`cowshed setup [--dry-run]`** prepares a server, and is safe to run again: Docker if
missing (needs root or sudo without a password), `~/.cowshed`, and Traefik if none
runs. It uses a Traefik already there, set up by flags or a YAML settings file, and
changes nothing that exists. It stops, saying why, at anything that would touch other
apps, such as a Traefik with no routes folder: `cowshed proxy adopt` gives it one. `--dry-run` says what it would do.

**`cowshed proxy adopt [--yes]`** gives a working Traefik a routes folder. Alone it says
what it would change, and changes nothing. With `--yes` it backs up the settings, the
Compose file and what Traefik mounts, certificates included, to `~/.cowshed/backups`;
tries the new settings in a throwaway container; then recreates Traefik alone, with the
same image. **That cuts every app it serves for some seconds**, so `--yes` is the
server owner's decision, per server, at a time that suits them. If an app got worse
afterwards, it puts everything back. It handles a Traefik from one Compose file with
a YAML settings file; anything else it refuses, saying what to add by hand.

## Deploying

**`cowshed deploy [--secrets <path>] [--dirty] [--force]`** builds the image on this
machine, sends what the server lacks, starts the new version beside the old one, checks
its health, moves the traffic, waits for the old one's connections and stops it. Until
the traffic moves, any failure leaves the old version untouched.

A deploy is built from a clean copy of what is committed. Changed files, new files and
what git ignores stay out, and it says how many differ. If what runs came from the same
commits, it says so and stops.

- `--dirty` ships this folder as it is, as a test: changes, new files and what git ignores,
  unless `.dockerignore` leaves them out.
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
images and their files. Without `--yes` it only lists them. The audit log, a container
named in `replaces` and what volumes hold stay.

**`cowshed lock status`**, **`cowshed lock release`** say who holds the deploy lock and
free it after a deploy that died.
