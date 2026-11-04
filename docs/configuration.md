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
  ssl_redirect: true      # HTTP goes to HTTPS, by default; false: HTTP reaches the app too
  acme_email: me@example.com  # Needed when `setup` installs Traefik, with ssl
  tcp:                    # Optional: raw TCP ports, the same inside and out
    - 60005
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
backup:                   # Optional: with `deploy --migrate`, on the server, first
  command: pg_dump mydb > "$COWSHED_BACKUP_DIR/db.sql"
  keep: 5                 # How many stay, by default
  timeout: 600            # Seconds, by default
migrate:                  # Optional: with `deploy --migrate`, before the new version
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
networks:                 # Optional: the project's own, beside Traefik's
  - my-app                # Made if missing, never removed
cpus: 2                   # Optional limits
memory: 1g
deploy_timeout: 30        # Seconds for the new version to prove healthy
drain_timeout: 30         # Seconds for the old one's connections to end
replaces: old-container   # Optional: from before Cowshed; stopped, never removed
accessories:              # Optional: long-lived containers beside the app
  db:                     # Runs as `<service>-db`
    image: postgres:17-alpine
    port: 127.0.0.1:5432:5432  # Optional: `--publish`
    cmd: postgres -c max_connections=200  # Optional
    env:                  # As the app's: clear and secret
      secret:
        - POSTGRES_PASSWORD
    files:                # Optional: from this folder, mounted read-only
      - config/db/init.sql:/docker-entrypoint-initdb.d/init.sql
    directories:          # Optional: a folder of its own on the server
      - data:/var/lib/postgresql/data
    volumes: []           # Optional: as the app's
    networks:             # Optional: the project's `networks` when left out
      - my-app
  auth:
    image: quay.io/keycloak/keycloak:26
    cmd: start
    proxy:                # Optional: a route through Traefik, as the app's
      host: auth.example.com
      app_port: 8080
      ssl: true
      healthcheck:
        path: /realms/master
    boot_timeout: 120     # Seconds to prove healthy, with proxy; 60 by default
```

A list of hosts can stand directly under `servers`, and a plain map under `env` is all
clear variables. `registry`, `boot` and `proxy.forward_headers` are read and ignored, with
a notice: Traefik sets the forwarding headers.

## Raw TCP

`proxy.tcp` lists ports that are not HTTP, such as a device's socket. Each reaches the
same port of the live version through an entrypoint of Traefik's own, switched with the
HTTP route in the same deploy, confirmed by Traefik's API, and drained like it:
connections already open stay with the old version until `drain_timeout`, then end, and
their clients must connect again. Without TLS nothing tells apps apart, so a port serves
one app. The Traefik `setup` installs gets an entrypoint and a published port for each.
A Traefik already there must have one listening on the port: an entrypoint is part of
Traefik's own settings, and adding one restarts it, so `setup` and `deploy` stop and
name the port instead. 80 and 443 are HTTP's.

## Plain HTTP beside HTTPS

With `ssl: true`, HTTP redirects to HTTPS. `ssl_redirect: false` lets HTTP reach the app as
well, for devices or callers that cannot speak HTTPS; the app then decides what to redirect, by
the `X-Forwarded-Proto` that Traefik sets. A Traefik whose HTTP entrypoint sends everything to
HTTPS itself (`entrypoints.<it>.http.redirections`) does so before any route, so `setup` and
`deploy` stop there and say so: removing that setting is the server owner's change, and
restarts Traefik. The Traefik `setup` installs has no such setting.

## Volumes

Every version, a rollback and `cowshed exec` see the same volumes. A missing path is made
by Docker, as root, so an app running as another user needs it prepared. Cowshed copies
nothing into them, and `remove` leaves them. During a switch the old and the new version
use them together, for up to `drain_timeout` seconds: a database file must allow that,
and a migration on start reaches the old version's data even if the new one then fails.
A rollback changes the code, not what volumes hold. [Usage](usage.md#data-that-must-outlive-a-version)
covers a first copy and backups.

## Networks

The app is on Traefik's network, shared by every app on the server, so that Traefik
reaches it. `networks` adds networks of the project's own, for what only the app should
reach, such as its database: what sits on them is out of other apps' sight, and Traefik's.

Every version, its migration and `cowshed exec` join them all from the start, so the app
never runs without its database. A network missing is made by `deploy`; one that exists is
used as it is, whoever made it. `remove` leaves them: something else may be on one. Docker
25 or later joins several networks at once. `host`, `none` and `bridge` are Docker's own and
refused: a container on them can join no other.

## Accessories

A database, an identity server: containers that live across deploys, named
`<service>-accessory-<name>` on the app's server, so `orbitx-accessory-db` for `db`
(the name the app reaches it by) (`host`, if given, must be the app's).
`cowshed accessory boot` starts one that does not exist, and `reboot` recreates one after
its settings change, a new image tag included; a deploy never touches them.
Their secrets come from the same secrets file, into an env file of their own; their
`files` are sent from this machine and mounted read-only; their `directories` are
folders on the server, in `~/.cowshed/accessories/<service>-accessory-<name>/directories/`, which
`cowshed accessory remove` keeps. They join the project's `networks` unless they name
their own, so the app reaches them by name and other apps do not.

With `proxy`, an accessory also joins Traefik's network, must answer 2xx on its health
path within `boot_timeout`, asked from inside Traefik, and then gets a route to its
container, `cowshed-<service>-accessory-<name>.yml`, as the app does. Its name does not change
across reboots, so neither does its route; `remove` takes it away. `setup` installs
Traefik for an accessory's route too.

## Backups

Cowshed does not know where an app keeps its data, so `backup.command` says how to copy it. It
runs with `deploy --migrate`, on the server, in a shell, as the SSH user, after the image arrives
and before `migrate`. It
must write into `$COWSHED_BACKUP_DIR`, a new private folder in
`~/.cowshed/backups/<service>/<time>-<version>/`. `$COWSHED_VERSION` and `$COWSHED_IMAGE` name the
new version, for a command that needs its image. The app's secrets are not given to it.

Anything but exit code 0, an empty folder or the end of its time stops the deploy, with nothing
changed. What it prints is dropped; the last lines of its errors are shown if it fails. After a
good one, only the newest `keep` stay. `remove` and a rollback leave them. They hold the app's data
and stay on the same disk: they protect from a bad migration, not from losing the server.

## Migrations

With `deploy --migrate`, `migrate.command` runs once, in a container of the new image, after it reaches
the server and before the new version starts. It has the app's variables, secrets, network and
volumes, and `migrate.env` on top of them; the app never sees those. Anything but exit code 0 stops the deploy, with the old version serving. Its
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
