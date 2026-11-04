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

`setup`, `proxy adopt`, `deploy` and `rollback` keep a copy of what they say on this machine, in
`~/.local/state/cowshed/logs/`, and name the file at the end. A build's own output stays on the
screen.

**`cowshed setup [--dry-run]`** prepares a server, and is safe to run again: Docker if
missing (needs root or sudo without a password), `~/.cowshed`, and Traefik if none
runs. It uses a Traefik already there, set up by flags or a YAML settings file, and
changes nothing that exists. It stops, saying why, at anything that would touch other
apps, such as a Traefik with no routes folder: `cowshed proxy adopt` gives it one, or
with no entrypoint on a `proxy.tcp` port. The Traefik it starts listens on 80, 443 and
those ports. `--dry-run` says what it would do.

**`cowshed proxy adopt [--yes]`** gives a working Traefik a routes folder. Alone it says
what it would change, and changes nothing. With `--yes` it backs up the settings, the
Compose file and what Traefik mounts, certificates included, to `~/.cowshed/backups`;
tries the new settings in a throwaway container; then recreates Traefik alone, with the
same image. **That cuts every app it serves for some seconds**, so `--yes` is the
server owner's decision, per server, at a time that suits them. If a router from a
container's labels is not enabled afterwards, or such a host answers `/` worse, it puts
everything back. The plan names those routers and hosts. Nothing else is checked, and `RESTORE FAILED` is explained in
[usage](usage.md#adopting-a-traefik). It handles a Traefik from one Compose file with
a YAML settings file; anything else it refuses, saying what to add by hand.

## Deploying

**`cowshed deploy [--secrets <path>] [--dirty] [--force] [--migrate]`** builds the image on this
machine, sends what the server lacks, starts the new version beside the old one, checks
its health, moves the traffic, waits for the old one's connections and stops it. With `--migrate`, the
config's `backup` and `migrate` run once, in that order, before the new version starts. Until the traffic moves, any failure
leaves the old version untouched, though not what a migration has done to the data.

A deploy is built from a clean copy of what is committed. Changed files, new files and
what git ignores stay out. It says how many files differ and names the new ones. If what runs came from the same
commits, it says so and stops.

- `--dirty` ships this folder as it is, as a test: changes, new files and what git ignores,
  unless `.dockerignore` leaves them out.
- `--force` deploys even if nothing changed.
- `--migrate` runs the config's `backup` and `migrate`. Without it neither runs, and it says so.
- `--stage` builds and sends the version, under the lock, and starts nothing: no container,
  no migration, no switch. `exec --version` can then run it, and a later deploy puts it
  live with nothing left to send. Not with `--migrate`. A deploy prunes a staged image
  it leaves out of the versions it keeps.

**`cowshed rollback <version>`** goes back to a version still on the server, with no
build. If it fails its health it is stopped again, and what is live stays live.

## Looking

**`cowshed versions`** lists what is on the server, what is live, when each was made, in the
server's time, and what it was made from.

**`cowshed logs [--lines <n>]`** shows the live container's latest logs (100 by default).

**`cowshed audit`** shows who deployed what and when.

**`cowshed exec [--version <v>] [--env NAME=value]... <command...>`** runs a new container
of a version, the live one's by default or one staged, with the live one's variables,
network and volumes, and removes it after. The words replace the image's `CMD`.
Its exit code decides the result. Its output comes when it ends.

`--env` sets a variable for this run alone, over the config's and the env file's: a
copy of the database to try a migration on, say. It is on the server's command line
like the config's clear variables, so a secret is refused by name: secrets travel only
by the env file. Only its name is said.

## Maintaining

**`cowshed prune`** removes what no kept version uses. A deploy does this too; the last
3 stopped containers stay for a rollback.

**`cowshed stop`** removes the route and stops what runs. The containers stay, and a
`rollback` brings one back.

**`cowshed remove [--yes]`** removes the app from the server for good: route, containers,
images and their files. Without `--yes` it only lists them. The audit log, a container
named in `replaces`, the project's networks and what volumes hold stay.

## Accessories

**`cowshed accessory [-c <path>] [--secrets <path>] <action> <name>`** works on the
config's long-lived containers, named `<service>-accessory-<name>`. A container of that
name not labelled as this project's accessory is someone else's: every action refuses it
and leaves it as it is.

- `boot <name|all>` starts one that does not exist: its networks, folders, env file
  and files, then the container, which must still run, never restarted, a few seconds
  later. With `proxy`, it must instead answer its health path within `boot_timeout`, and
  then gets its route. One that runs is left as it is; one that is stopped is told to `start`.
- `reboot <name|all>` recreates it from the config as it is now: a new image tag, other
  settings, new secrets or files. Its data, in its directories, carries over. All that can
  fail is done first; then the old container is set aside and stopped, **which cuts what it
  serves**, and the new one must stay up. If it does not, the old one is put back as it
  was. One that does not exist is booted.
- `start <name|all>` and `stop <name|all>`: the same container, with what it holds.
- `logs <name> [--lines <n>]`: its latest logs.
- `exec <name> <command...>`: a command in the running container, as a database's own
  tools need. Its exit code decides; its output comes when it ends.
- `remove <name> [--yes]`: the container, its env file, the files sent and its route.
  Its directories and volumes stay. Without `--yes` it only lists them.

**`cowshed lock status`**, **`cowshed lock release`** say who holds the deploy lock and
free it after a deploy that died.
