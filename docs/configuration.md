# Configuration

`config/deploy.yml`, one for each project. An option Cowshed does not know is refused by
name. Only block YAML: maps, lists, scalars, comments, `|` and `>`.

```yaml
service: my-app           # Names its containers, route, lock and log
image: my-app             # Names its image on the server
servers:
  web:                    # The role; one for now
    hosts:
      - example.com       # One for now
    cmd: --port 8000      # Optional: arguments for the container
    labels:               # Optional: Docker labels
      some.label: "value"
ssh:
  user: deploy            # root by default
  port: 22
  keys:
    - ~/.ssh/my_key
proxy:                    # Optional: without it there is no route
  host: app.example.com
  app_port: 8000          # 80 by default
  ssl: true               # HTTPS, with a certificate from Traefik's resolver
  ssl_redirect: true      # HTTP goes to HTTPS, by default
  acme_email: me@example.com  # Needed when `setup` installs Traefik, with ssl
  healthcheck:
    path: /up             # By default; must answer 2xx
    interval: 1           # Seconds between tries
    timeout: 5            # Seconds for each
env:
  clear:
    MODE: production      # Seen in `docker inspect`
  secret:
    - API_TOKEN           # From the secrets file
    - DB_PASSWORD:PG_PASS # Seen as DB_PASSWORD, read from PG_PASS
secrets: .cowshed/secrets # By default
env_file: ~/.my_secrets   # Optional: variables the secrets file reads
backup:                   # Optional: runs on the server before each new version
  command: pg_dump mydb > "$COWSHED_BACKUP_DIR/db.sql"
  keep: 5                 # How many stay, by default
  timeout: 600            # Seconds, by default
migrate:                  # Optional: runs before each new version
  command: ./my-app       # Replaces the image's CMD
  env:
    MIGRATE: "1"          # Only for this command
  timeout: 300            # Seconds, by default
builder:
  before: tools/stage.sh  # Optional: run first, with COWSHED_VERSION set
  context: .              # By default
  dockerfile: Dockerfile  # By default
  arch: arm64             # Optional
volumes:                  # Optional: what must outlive a version
  - /var/lib/my-app:/data   # A path on the server, or a Docker volume's name
  - shared:/shared:ro       # Then `:ro`, `:rw`, `:z` or `:Z`, if needed
cpus: 2                   # Optional limits
memory: 1g
deploy_timeout: 30        # Seconds for the new version to prove healthy
drain_timeout: 30         # Seconds for the old one's connections to end
replaces: old-container   # Optional: from before Cowshed; stopped, never removed
```

A list of hosts can stand directly under `servers`, and a plain map under `env` is all
clear variables. `registry`, `boot` and `proxy.forward_headers` are read and ignored, with
a notice: Traefik sets the forwarding headers.

## Volumes

Every version, a rollback and `cowshed exec` see the same volumes. A missing path is made
by Docker, as root, so an app running as another user needs it prepared. Cowshed copies
nothing into them, and `remove` leaves them. During a switch the old and the new version
use them together, for up to `drain_timeout` seconds: a database file must allow that,
and a migration on start reaches the old version's data even if the new one then fails.
A rollback changes the code, not what volumes hold. [Usage](usage.md#data-that-must-outlive-a-version)
covers a first copy and backups.

## Backups

Cowshed does not know where an app keeps its data, so `backup.command` says how to copy it. It
runs on the server, in a shell, as the SSH user, after the image arrives and before `migrate`. It
must write into `$COWSHED_BACKUP_DIR`, a new private folder in
`~/.cowshed/backups/<service>/<time>-<version>/`. `$COWSHED_VERSION` and `$COWSHED_IMAGE` name the
new version, for a command that needs its image. The app's secrets are not given to it.

Anything but exit code 0, an empty folder or the end of its time stops the deploy, with nothing
changed. What it prints is dropped; the last lines of its errors are shown if it fails. After a
good one, only the newest `keep` stay. `remove` and a rollback leave them. They hold the app's data
and stay on the same disk: they protect from a bad migration, not from losing the server.

## Migrations

`migrate.command` runs on every deploy, once, in a container of the new image, after it reaches
the server and before the new version starts. It has the app's variables, secrets, network and
volumes, and `migrate.env` on top of them; the app never sees those. A command with nothing to do
should end at once. Anything but exit code 0 stops the deploy, with the old version serving. Its
output comes when it ends. A rollback runs nothing.

Keep a variable that makes the app migrate and exit in `migrate.env`, never in `env`: the app
would exit instead of serving.

## What goes into the image

Only what is committed: a deploy builds from a clean copy of the repository, in
`~/.cache/cowshed/clones/<service>/`. A build needing what git ignores must fetch or make
it itself; `builder.before` runs in that copy. The config and the secrets file are read
from this folder. `cowshed deploy --dirty` builds this folder instead, as a test.

The copy is kept between deploys, so what git ignores there stays: a file made or fetched by
one build can enter the next. Deleting the folder starts it afresh.

## A project among others, or using other repositories

```yaml
branch: main
sources:
  - .
  - ../../engine
```

`branch` builds that branch's commit, whatever is checked out here. `sources` lists what
else makes up the project, each copied clean: if none changed since what is live, the
deploy says so and stops.

## The secrets file

`NAME=value` lines; comments start with `#`.

```sh
PLAIN=value
FROM_ENVIRONMENT=$SOME_VARIABLE
FROM_A_COMMAND=$(pass show my-app/token)
LITERAL='$not expanded'
```

Only the secrets the config uses are expanded, and commands run on this machine. A value
cannot hold a line break. Keep the file out of git.

A `$VARIABLE` comes from the environment, or else from `env_file`:

```yaml
env_file: ~/.my_secrets
```

`deploy` runs that file with `sh`, on this machine, for that command alone, and only if the
config uses secrets. Plain assignments and `export` both work; it must be valid for `sh`, and it
is executed, so it must be yours. What is already in the environment wins. A missing or failing
file stops the deploy before any build, and what the file prints is dropped. `check` only looks
that it is there. Commands written as `$(...)` in the secrets file do not see its variables.
Only `deploy` reads secrets: `exec` and `rollback` use what the version already has.
