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
git add <the files>       # `git commit -a` alone leaves new files out
git commit -m "What changed"
git status                # Nothing you meant to ship should be listed
cowshed deploy
```

- **Only what is committed goes,** from the repository on this machine: no push is needed.
  Read the notices: they say how many files differ here and name the new ones, and none of
  them is in this deploy. The build may still pass without them.
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

If your variables live in a file of your own, name it in `config/deploy.yml`, and a deploy runs
it with `sh`, for that command alone:

```yaml
env_file: ~/.my_secrets
```

Only the path is in the repository. Only `deploy` needs secrets: `exec` and `rollback` use what the
version already has. Without `env_file`, load your file first, exporting its variables.

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

**Back up before a deploy that migrates,** with `backup` in the config, or by hand as here. A migration changes the old version's
data too, even if the new version then fails. The app's own backup command can run with the
live version's settings and volumes, and the copy be taken off the server:

```bash
cowshed exec ./my-app backup /data/backup-2026-01-31.db
scp root@my-server:/var/lib/my-app/backup-2026-01-31.db .
```

**A rollback changes the code, not the data.** After a migration the old version meets the
new schema, and may fail on it. Going back further means restoring that backup by hand, in
this order: `cowshed stop`; on the server, replace the database file and delete its old `-wal`
and `-shm` files; `cowshed rollback <version>` to the version that matches the backup. All that was written after
the backup is lost, and whatever else in the volume goes with the database, such as uploaded
files, must return with it.

## Migrations

Say once how the app migrates, in `config/deploy.yml`. A deploy that has a migration asks for it by
name, and only then does it run, from the new image, before the new version starts:

```yaml
migrate:
  command: ./my-app
  env:
    MIGRATE: "1"
```

**The backup is in the deploy too.** Cowshed does not know your database, so you say how to copy it,
once, and it runs on the server before the migration:

```yaml
backup:
  command: docker exec my-db pg_dump -U me -Fc mydb > "$COWSHED_BACKUP_DIR/mydb.dump"
```

An app whose tool is in its image runs that image, with the volume and the folder mounted:

```yaml
backup:
  command: >
    docker run --rm -v /var/lib/my-app:/data -v "$COWSHED_BACKUP_DIR:/out"
    "$COWSHED_IMAGE" ./my-app backup /out/my-app.db
```

Then a deploy with a migration, its backup included, is one command, and any other stays as it was:

```bash
cowshed deploy --migrate    # This version has a migration
cowshed deploy              # It has none: no backup, no migration
```

**Forgetting `--migrate`** depends on the app. One that refuses to start with a migration pending
fails its health check, and the old version keeps serving. One that migrates when it starts does so
with no backup: such an app should refuse in production, and leave migrating to this command.

- **The first deploy:** the command must cope with there being nothing to copy yet, or be added after
  it. If it fails, nothing is deployed.
- **A command using the new image runs the new code before any migration.** If that code migrates or
  changes the data when it starts, the copy is already of the changed data. Check that its backup
  command does neither.
- **What it copies is what you wrote:** files beside a database, such as uploads, must be in the
  command too. Try restoring one: Cowshed proves only that the folder is not empty.
- **It stays on the server,** in `~/.cowshed/backups/<service>/`, with personal data if the app has
  any. Copying it elsewhere is yours to arrange.

- **It fails:** the old version keeps serving. What the migration did before failing stays, unless
  it undoes itself. Read its output, shown when it ends.
- **It passes and the new version then fails its health check:** the old version keeps serving on
  the new schema, so a migration must be one the old version can live with until the switch. One
  it cannot needs a window the people using the app know about.
- **It passes its `timeout`:** it is stopped, perhaps half done. Raise the limit if it was only
  slow, and look at the data before trying again.
- **Going back:** a rollback runs no migration, and the data stays as it is.

## Running one command

`cowshed exec <command...>` starts a new container of the live version, with its variables,
network and volumes. The words replace the image's `CMD` and follow any `ENTRYPOINT`, and run in
its `WORKDIR`, so write them as there: `./my-app backup`, if it is not on the `PATH`. It needs a
version on the server: there is nothing to run before the first deploy.

## The client's address

Traefik sets `X-Forwarded-For` and the like, and `proxy.forward_headers` changes nothing. Whether
to believe them is the app's decision: it should trust only what comes from Traefik's network.
On the server, `docker inspect <traefik>` names its networks, and `docker network inspect <network>`
shows their addresses.

## The first certificate

`deploy` asks the address from outside for about 30 s and only tells what it found, as a new
certificate may take longer. Traefik's first certificate resolver is the one used. Let's Encrypt
must reach the server on the domain, and Traefik serves its own default certificate until then.

```bash
curl -I https://app.example.com/up                  # Still failing a few minutes later?
ssh root@my-server 'docker logs <traefik> 2>&1 | grep -i -E "acme|certificate" | tail'
```

A log line naming the domain with an error is a failure, not a delay. Check the DNS, and that
ports 80 and 443 reach the server. Repeating deploys does not help: Let's Encrypt limits attempts.

## Long connections

Server-sent events and WebSockets keep the old version's connections open, so a deploy waits
all of `drain_timeout`, then stops what remains. Clients must reconnect by themselves. A
lower `drain_timeout` makes the deploy shorter and the versions overlap less, and cuts those
clients sooner. Timeouts in a Traefik Cowshed did not set up are its own, and Cowshed leaves
them as they are: try a long connection through it.

## Adopting a Traefik

The plan, without `--yes`, names the routers and hosts it will check.

Before the cut it tries the new settings in a throwaway container, and if that fails nothing
has changed. After the cut, for up to 30 s, it compares each app with how it was:

- The routers from running containers' Docker labels must be enabled.
- Each host in those labels is asked for `/` by HTTP and HTTPS, from the server. An answer that
  stays the same or becomes 2xx or 3xx is fine, so one that was already 404 or 500 and stays
  so passes. Without `curl` on the server only the routers count, and it says so.

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

Leave `mount-<n>` where it is unless a file there was damaged: an old `acme.json`, for one, would
lose the certificates issued since. These steps are the server owner's to run or approve.

**Its API.** Cowshed needs Traefik's API to confirm a switch, and the API has no password. A new
API answers only inside Traefik's container. An API the settings already had, an entrypoint named
`traefik` or settings with no `entryPoints` stay as they are, and then the API is unpublished but
open to every container on Traefik's networks; the plan says so. It shows routes, not secrets. To
close it, add this to the settings when a restart suits every app:

```yaml
entryPoints:
  traefik:
    address: "127.0.0.1:8080"
```

**A floating image.** `traefik:latest` may bring another version the next time the container is
recreated, by anyone. Adopting keeps the image in use, with no pull. Pinning a version where it is
defined is the owner's decision, and takes effect at a restart.

There is no command to undo an adoption that succeeded yet. The same steps do it, and cut the
apps again. **Apps Cowshed publishes on that Traefik then lose their routes and go off the air,**
as the routes folder is no longer read: `cowshed stop` them first.

## Running it

| To | Run |
|---|---|
| See the versions, and what is live | `cowshed versions` |
| Read the live container's logs | `cowshed logs --lines 200` |
| Run a one-off command | `cowshed exec <command...>` |
| See who deployed what | `cowshed audit` |
| Go back, with no build | `cowshed rollback <version>` |
| Take the app off the air | `cowshed stop` (a `rollback` brings it back) |
| Start a database or another accessory | `cowshed accessory boot <name>` |
| Run a command in one | `cowshed accessory exec <name> <command...>` |
| Change one's image or settings | Edit the config, then `cowshed accessory reboot <name>`: a cut |
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
| `sends all of ... to HTTPS itself` | `ssl_redirect: false` needs plain HTTP, and that Traefik redirects first. Its owner can remove the redirection, with a restart; or keep the redirect |
| `Traefik did not take the new route` | Read what the message says: a broken file in the routes folder blocks every change there |
| `the apps did not come back as they were` | Everything was put back. Read which app it names, and find out why before trying again |
| `RESTORE FAILED` | Urgent: Traefik may be down. Call the server owner at once. See [Adopting a Traefik](#adopting-a-traefik) |
| `notice: from outside: ... did not answer` | Not known yet: DNS or a first certificate may take longer. See [The first certificate](#the-first-certificate) |

## Limits worth knowing

- **The clean copy is kept between deploys,** in `~/.cache/cowshed/clones/<service>/`, so
  downloads need not come again. What git ignores stays there: a file made or fetched by one
  build can enter the next. If a stale one is suspected, delete that folder.
- **A clean copy has no git submodules.** A build that needs them fails.
- One server and one role per project.
- Proven on a real server: `proxy adopt`, a first certificate, a deploy with a volume, a second
  deploy and a rollback.
- Proven on a real server too: `backup` and `migrate`, with a real migration.
- Not yet proven on a real server: server-sent events over HTTPS, and
  `proxy adopt` putting things back by itself after the cut, which has run only against a fake.

## For a coding agent

Follow the steps above, and these rules:

- **Never print a secret's value,** nor put one on a command line, in a log or in a commit.
  Refer to secrets by name. `cowshed exec` returns all a command prints: a command that shows
  a token or password is for the owner to run in their own terminal: a command run through your
  session, even by them, puts its output in front of you.
- **Ask the owner first, each time,** for `cowshed proxy adopt --yes`, `cowshed remove --yes`,
  `cowshed lock release`, `cowshed stop`, `cowshed rollback`, and `cowshed accessory stop` or
  `remove --yes`, and `cowshed accessory reboot`: the app goes down without its database, for
  good or for some seconds. On a server other apps share,
  also for `cowshed setup`, the first `cowshed deploy` and any copy into a volume. An earlier
  yes does not extend to another server or another time. The owner's own rules come before this
  list.
- **Do not edit Traefik's settings, its routes or other apps' containers by hand.** If Cowshed
  stops at one of them, report what it said. After `RESTORE FAILED` too: call the owner, and run
  the steps by hand only with the owner's yes.
- **Do not reach for `--dirty` or `--force` to get past a message.** Read it first. Commit what
  should ship.
- **Run what changes nothing first:** `check --remote` and `setup --dry-run`. `proxy adopt`
  without `--yes` shows the plan to give the owner.
- **Check the result:** `cowshed versions`, and the `from outside` line of the deploy. Report
  what failed as it failed.
