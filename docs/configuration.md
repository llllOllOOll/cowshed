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
clear variables. `registry` and `boot` are read and ignored, with a notice.

## Volumes

Every version, a rollback and `cowshed exec` see the same volumes. A missing path is made
by Docker, as root, so an app running as another user needs it prepared. Cowshed copies
nothing into them, and `remove` leaves them. During a switch the old and the new version
use them together, for up to `drain_timeout` seconds: a database file must allow that,
and a migration on start reaches the old version's data even if the new one then fails.

## A project among others, or using other repositories

```yaml
branch: main
sources:
  - .
  - ../../engine
```

With either, a deploy builds from clean copies at that branch's commit, in
`~/.cache/cowshed/clones/<service>/`, whatever is checked out here. Other work in the
folder stays out. `sources` also lists what makes up the project: if none changed since
what is live, the deploy says so and stops.

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
