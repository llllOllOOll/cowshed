# Using Cowshed

From a project with a Dockerfile to a version on the air, and what to do when something
stops. For people and for coding agents alike. Every option is in
[commands](commands.md) and [configuration](configuration.md).

## Installing

Build with Zig 0.17 on your machine, then put the binary on your `PATH`; the server needs
nothing of it:

```bash
zig build
cp zig-out/bin/cowshed ~/.local/bin/
```

## What a project needs

- A git repository with at least one commit, and a Dockerfile.
- SSH access to the server by key.
- For HTTPS, a domain whose DNS already points to the server.
- An app that answers 2xx on its health path, `/up` by default, without a login.

## From nothing to the first deploy

```bash
cowshed init --host my-server --domain app.example.com
```

This writes `config/deploy.yml` and `.cowshed/secrets`, and keeps the secrets out of git.
It reaches no server. Fill in what it says, then commit the project.

```bash
cowshed check --remote     # Reads the config, reaches the server. Changes nothing
cowshed setup --dry-run    # Says what setup would do. Changes nothing
cowshed setup              # Docker, folders, and Traefik if none runs
cowshed deploy
```

Nothing above changes what already runs on the server, with one exception: a Traefik with
no routes folder. `setup` stops there and says so:

```bash
cowshed proxy adopt        # Says what it would change. Changes nothing
cowshed proxy adopt --yes  # The server owner's decision: see below
cowshed setup
```

`--yes` restarts Traefik and **cuts every app behind it for some seconds**. Choose a time
that suits those apps. See [Adopting a Traefik](#adopting-a-traefik).

If `config/deploy.yml` already exists, `init` stops and changes nothing: edit that file, or
move it away and run `init` again. `check` names any option Cowshed does not know.

## Deploying

```bash
git commit -am "What changed"
cowshed deploy
```

- **Only what is committed goes,** from the repository on this machine: no push is needed.
  Read the notice saying how many files differ here: they are not in this deploy.
- **The same commit again** says "nothing changed" and ends, with no error and nothing
  deployed. `--force` deploys it anyway.
- **`--dirty`** builds this folder as it is, as a test, and what git ignores can enter.
  Do not use it for a real release.
- **The config and the secrets file** are read from this folder, committed or not: a change
  to `config/deploy.yml` counts at once.

## Secrets

Name them in `config/deploy.yml`, under `env.secret`; their values come from
`.cowshed/secrets`. A line there can read a variable of this shell, so the variable must be
set when the command runs:

```sh
API_TOKEN=$MY_API_TOKEN
DB_PASSWORD=$(pass show my-app/db)
```

If your variables live in a file of your own, load it for that command:

```fish
source ~/.my_secrets; and cowshed deploy     # fish
```

```bash
source ~/.my_secrets && cowshed deploy       # bash, zsh
```

Variables must be exported for Cowshed to see them.

## Data that must outlive a version

```yaml
volumes:
  - /var/lib/my-app:/data
```

During a switch the old and the new version use the volume together, for up to
`drain_timeout` seconds. A database file must allow that. Cowshed copies nothing into a
volume, and `remove` leaves it.

**Existing data goes in before the first deploy,** by hand. The path is on the server:

```bash
ssh root@my-server mkdir -p /var/lib/my-app
scp my-app.db root@my-server:/var/lib/my-app/
```

A path Docker makes itself belongs to root, so an app running as another user needs it
prepared with `chown`. Copy a database from a consistent backup, not from the files of one
in use: SQLite in WAL mode, for one, keeps recent changes in `-wal` and `-shm` files beside
the main one.

**Back up before a deploy that migrates.** A migration on start changes the old version's
data too, even if the new version then fails. The app's own backup command can run with the
live version's settings and volumes, and the copy be taken off the server:

```bash
cowshed exec my-app backup /data/backup-2026-01-31.db
scp root@my-server:/var/lib/my-app/backup-2026-01-31.db .
```

**A rollback changes the code, not the data.** After a migration the old version meets the
new schema, and may fail on it. Going back further means restoring that backup by hand.

## Long connections

Server-sent events and WebSockets keep the old version's connections open, so a deploy waits
all of `drain_timeout`, then stops what remains. Clients must reconnect by themselves. A
lower `drain_timeout` makes the deploy shorter and the versions overlap less, and cuts those
clients sooner. Timeouts in a Traefik Cowshed did not set up are its own, and Cowshed leaves
them as they are: try a long connection through it.

## Adopting a Traefik

Before the cut it tries the new settings in a throwaway container, and if that fails nothing
has changed. After the cut, for up to the limit it shows, it compares each app with how it was:

- The routers from running containers' Docker labels must be enabled.
- Each host in those labels is asked for `/` by HTTP and HTTPS, from the server. An answer that
  stays the same or becomes 2xx or 3xx is fine. Without `curl` on the server only the routers
  count.

If either fails, it puts the files back and recreates Traefik, and says so.

**It sees nothing else.** Other paths, WebSockets, routes from Traefik's files and anything not
behind Traefik are yours to check before and after, and so is whatever is in use at that moment:
a call, a long job, a connection the app cannot get back. It cuts only what passes through
Traefik, but it does not know what a cut costs.

A backup stays in `~/.cowshed/backups/traefik-<time>/`, private, with certificate keys inside:
`compose` and `settings` are the two files as they were, `mount-<n>` what Traefik mounted.

**`RESTORE FAILED`** means it could not finish putting things back: Traefik may be down, and
every app with it. The line says what is left to do. By hand, on the server, using the paths
that `proxy adopt` showed:

```bash
cp -p ~/.cowshed/backups/traefik-<time>/compose <compose file>
cp -p ~/.cowshed/backups/traefik-<time>/settings <settings file>
cd <its folder> && docker compose up -d <service>
```

There is no command to undo an adoption that succeeded yet. The same steps do it, and cut the
apps again.

## Running it

| To | Run |
|---|---|
| See the versions, and what is live | `cowshed versions` |
| Read the live container's logs | `cowshed logs --lines 200` |
| Run a one-off command | `cowshed exec <command...>` |
| See who deployed what | `cowshed audit` |
| Go back, with no build | `cowshed rollback <version>` |
| Take the app off the air | `cowshed stop` (a `rollback` brings it back) |
| See what removing would take | `cowshed remove` |

## When something stops

A line beginning with `stopped:` says why. Until the traffic moves, a failed deploy
leaves the old version serving.

| It says | Do |
|---|---|
| `another deploy holds the lock` | Wait for that deploy. Only if it died: `cowshed lock status`, then `cowshed lock release` |
| `did not pass its health check` | Its logs were just shown, and the container is gone. Fix the app, commit, deploy again |
| `nothing changed` | Commit what you meant to ship, or use `--force` to repeat the version |
| `has no commit yet` | Make the first commit |
| ``secret `X` uses `$Y`, which is not set`` | Set and export `Y`, or load your file first |
| ``secret `X` is not in`` | Add `X` to `.cowshed/secrets` |
| `the image did not build` | Build it from what is committed. A missing file is often one git ignores: commit it, or have the build fetch it |
| `` `builder.before` failed`` | It runs in the clean copy: it cannot see files that exist only in this folder |
| `no Traefik runs on this server` | `cowshed setup` |
| `Traefik did not take the new route` | Read what the message says: a broken file in the routes folder blocks every change there |
| `the apps did not come back as they were` | Everything was put back. Read which app it names, and find out why before trying again |
| `RESTORE FAILED` | Act now: Traefik may be down. See [Adopting a Traefik](#adopting-a-traefik) |
| `notice: from outside: ... did not answer` | Not a failure: DNS or a first certificate may take longer. Check the address again in a moment |

## Limits worth knowing

- **The clean copy is kept between deploys,** in `~/.cache/cowshed/clones/<service>/`, so
  downloads need not come again. What git ignores stays there: a file made or fetched by one
  build can enter the next. If a stale one is suspected, delete that folder.
- **A clean copy has no git submodules.** A build that needs them fails.
- One server and one role per project.
- Not yet proven on a real server: a first certificate for a new domain, a deploy with a
  volume, and server-sent events over HTTPS. `proxy adopt` has run on one and was undone by
  hand; putting things back by itself after the cut has run only in tests, without a server.

## For a coding agent

Follow the steps above, and these rules:

- **Never print a secret's value,** nor put one on a command line, in a log or in a commit.
  Refer to secrets by name. `cowshed exec` returns all a command prints: a command that shows
  a token or password is for the owner to run, not you.
- **Ask the owner first, each time,** for `cowshed proxy adopt --yes`, `cowshed remove --yes`,
  `cowshed lock release` and `cowshed stop`. An earlier yes does not extend to another server
  or another time.
- **Do not edit Traefik's settings, its routes or other apps' containers by hand.** If Cowshed
  stops at one of them, report what it said.
- **Do not reach for `--dirty` or `--force` to get past a message.** Read it first. Commit what
  should ship.
- **Run what changes nothing first:** `check --remote` and `setup --dry-run`. `proxy adopt`
  without `--yes` shows the plan to give the owner.
- **Check the result:** `cowshed versions`, and the `from outside` line of the deploy. Report
  what failed as it failed.
