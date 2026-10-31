# Cowshed: design (draft, not approved)

Cowshed deploys Docker containers over SSH to a server, as one Zig binary. It
takes over from Kamal in the owner's projects and from each game's
`tools/deploy.sh`. On the server it needs only Docker and SSH.

Status of what follows: Kamal's flow was read in the gem (2.10.1). kamal-proxy
(01ec8b8) and Traefik (master 38d53dd, v3.8-rc era) were read in source. Traefik's
runtime behaviour was then tested on 3.6.6, locally: docs/spikes.md. Nothing has
been run on a real server yet.

## What the projects use

Eight `config/deploy.yml` were read for structure only, no values: orbitx,
orbitx-membros, orbitx-logs, orbitx-ia, orbitx-financeiro, smoney, smoney-prod,
spiderme_old.

- Each has one role (`web`) and one host, on 3 distinct servers (5 on one, 2 on
  another, 1 on a third). Multi-host and multi-role deploys are not needed yet.
- Options in use: `service`, `image`, `servers.web.{hosts,labels}`, `registry`,
  `builder.{arch,context,dockerfile}`, `env.{clear,secret}`,
  `proxy.{host,app_port,ssl,ssl_redirect,forward_headers}`, `ssh.{user,keys}`,
  `boot.{limit,wait}`, `deploy_timeout`, `accessories`.
- Accessories in use: `db` (7), `keycloak` (5, routed through the proxy with a
  health check), `autocgi_proxy` (5), with `image`, `host`, `port`, `cmd`, `env`,
  `files`, `directories`, `volumes`.
- The orbitx family also sets Traefik TCP labels on the app (`autocgi`).
- YAML: no anchors or merges. One folded block (`cmd: >`). ERB only in comments.
  No active hooks anywhere.
- `.kamal/secrets` exists in orbitx, smoney, smoney-prod and spiderme_old, and
  uses `$(...)` command substitution. The other orbitx-* have none in their own
  folder (where theirs come from is not yet read).

## Commands

| Command | Does |
|---|---|
| `cowshed check [--remote]` | Reads the config and the secrets' names, running no secret's command; `--remote` also reaches the server and Docker. Changes nothing |
| `cowshed setup` | Prepares a server for its first deploy, safe to run again (below) |
| `cowshed deploy` | The flow below |
| `cowshed rollback VERSION` | The same switch, on a container still on the server: no build. If it fails its health it is stopped again, and what is live stays |
| `cowshed versions` | Versions on the server, which one is live |
| `cowshed logs [--lines N]` | The live container's latest logs |
| `cowshed exec [--version V] CMD` | A one-off in a new container of a version, with the live one's variables, network and env file; its exit code decides. For migrations: OrbitX runs `SPIDER_MIGRATE=1 ./orbitx` before deploying |
| `cowshed prune` | Keeps the last 3 stopped containers; removes the images, blobs and lists of every other version, failed deploys' too |
| `cowshed stop` | Removes the route and stops what runs; containers stay, a `rollback` brings one back |
| `cowshed remove --yes` | Route, containers, images and their files, for good. Without `--yes` it only lists them. Audit log, accessories and `replaces` stay |
| `cowshed lock status / release` | The deploy lock |
| `cowshed audit` | Who deployed what and when |
| `cowshed accessory boot / stop / logs / exec NAME` | Long-lived services (database, Keycloak) |

## A project in a monorepo

Each project has its own `config/deploy.yml`, and runs from its own folder. With
`branch` or `sources`, what goes is what is committed, whatever is checked out here:

    branch: main
    sources:
      - .
      - ../../engine

- **Clean copies:** each source's repository is copied to
  `~/.cache/cowshed/clones/<service>/`, keeping their places relative to each other,
  and set to the branch's commit. Others' uncommitted work is told and left out.
  Copies are kept: what git ignores, a build's downloads, need not come again.
- **Version:** the project's repository commit, as in Kamal. It says nothing of
  whether the project changed, since a monorepo's commit may be another project's.
- **Whether it changed:** `game@abc,engine@def`, the last commit touching each source,
  is kept on the container and in the audit log. If what runs has the same, the deploy
  says so and stops; `--force` goes on. `versions` shows it.
- `--dirty` builds this folder as it is, as a test.

## The first setup

There is no Cowshed proxy: Traefik is the proxy. `cowshed setup` creates what a
new server lacks and changes nothing that exists:
1. **Docker:** if missing, install it with Docker's convenience script, as Kamal
   does; this needs root. Without root, stop and say what to do.
2. **Network:** the one the running Traefik watches, or a new `cowshed` network.
3. **Traefik:** apply "The proxy" below. Ours, `cowshed-traefik`, is pinned to the
   version tested and runs on 80 and 443 with a Let's Encrypt resolver, a persisted
   `acme.json` and the routes folder mounted, and its API reachable only from inside
   the network. It gets no Docker socket: routes come from files alone, so labels
   work only on a Traefik the server already had. Let's Encrypt needs an email:
   `proxy.acme_email`. If stopped, it is started again, never replaced.
4. **Cowshed's folders:** `~/.cowshed`, in the SSH user's home. Route files go
   straight in Traefik's folder, whose subfolders are not watched.

`--dry-run` asks the server everything, says what would happen and changes nothing.
What it read about a Traefik is not kept: each deploy reads it again.

## The deploy, in order

Every step says what it is doing as it starts, also through a pipe, and a wait says
how far along it is every 5 s.

1. Read the config and resolve secrets locally; stop on anything missing.
2. Check the host: Docker, proxy (below), disk.
3. Take the lock: `mkdir` on the server, atomic, with who, when and which version
   inside. Released on failure too. The build runs before it, as in Kamal.
4. Get the image to the server (below).
5. Write the env file for this version on the server, mode 0600; secrets never
   go on a command line.
6. Run `<service>-<role>-<version>` beside the old one, on the shared network,
   with `--restart unless-stopped`. If that version's name already exists, rename
   the old container first.
7. Health: probe the new container directly, from Traefik's container, on the
   configured path: every 1 s, 5 s per probe, 2xx only, within `deploy_timeout`
   (default 30 s). On failure: show its logs, stop it. The old one keeps serving,
   untouched.
8. Refuse if another file in Traefik's folder names our router (an earlier one would
   win), then switch: write the app's file to a temporary name without a `.yml`
   extension and rename it into place.
9. Confirm: poll Traefik's API for up to 15 s until the service shows the new
   container. On failure: put the old file back, remove the new container and name
   the likely cause, since a broken file elsewhere blocks everything. Its YAML is not
   checked beforehand: other people's files may use YAML our parser refuses.
10. Drain (below), then `docker stop` the old container. It stays for rollback.
11. Prune, append to the audit log, release the lock.
12. Request the app's real URL from this machine. Only told, not a failure: DNS or a
    first certificate may take longer.

The same version deployed again takes a new name (`-2`), so the live route's name
keeps meaning the running container. Uncommitted work (`--dirty`) is
`<commit>-dirty-<time>`. Secrets: only those the config uses are expanded or run.
`replaces: <container>` stops, and never removes, a container from before Cowshed.

## The proxy: Traefik through its file provider

Look at the host first:
- **A Traefik with a file provider:** use it. Read its network, entrypoint and
  certificate resolver from its flags in `docker inspect`, never its environment,
  which may hold secrets. Configured by a static file or environment instead: stop
  and say so, for now.
- **A Traefik without one:** stop and explain. Adding it means restarting Traefik
  or recreating its container, which touches every other app on that host. Only
  with the owner's explicit yes, never silently.
- **Nothing on 80/443:** start our own, with a persisted `acme.json`.
- **kamal-proxy:** a server still on Kamal. See Migration.
- **Anything else (nginx, Caddy):** stop with a clear message.

Each app owns one file holding its routers and services, so a switch is one
rename. It addresses the versioned container by name
(`http://<service>-<role>-<version>:<port>`) and changes the URL to switch; no
shared alias, because moving a name causes no reload and leaves idle connections
behind.

What the source says this costs us, and what Cowshed does about it:

| Traefik's behaviour | Cowshed |
|---|---|
| A change went live in 0.16-2.3 s when tested, and entrypoints switch one at a time | Step 9: confirm by the API, then from outside |
| A syntax error in any file blocks all later changes in the folder, for every app, seen only in its logs | A change not showing within 15 s fails, is put back and says so |
| With duplicate names, the first file by name wins, with only a log line | Names prefixed `cowshed-<service>-`; refuse a clash found in the folder |
| Health checks do not gate traffic (servers start UP) and reset on any reload | Cowshed's own probe, step 7, before the switch |
| A single bind-mounted file breaks on rename | Directories only; `setup` checks |
| The routes folder may not be writable from the host (the VPS: root, no sudo) | Write, probe and read the API through `docker exec` on Traefik's container, with its image's `sh` and `wget` |
| Same rule by label and by file: the labelled router kept winning | File routers carry a high `priority` |
| A resolver is static config: a router naming an unknown one only logs an error | Read the resolvers first, refuse an unknown one |
| The switch has no per-server connection count or drain signal | Count from the container's side (below) |

## Drain: where Cowshed differs from Kamal

kamal-proxy waits up to 30 s for ordinary requests but **cuts WebSockets at once**.
With Traefik, tested, WebSockets stay on the old container until either side
closes; requests under way should too (read in source, not tested); keep-alive clients move on their
next request, and no setting bounds any of it.

So Cowshed bounds it: each route sets a short `idleConnTimeout`, otherwise Traefik's
pool keeps idle connections to the old container for about 95 s. After the switch
Cowshed reads `/proc/<pid>/net/tcp` until the old container has no established
connections or `drain_timeout` passes (default 30 s), then stops it. A WebSocket
keeps running on the old version until then, and is cut by the stop.

## Getting the image there, without a registry

One way, for every project: build the image here, then send only what the server
lacks. `docker save` gives an OCI layout; Cowshed compares its `blobs/sha256/*` with
a folder on the server, sends the missing ones over `ssh`, tars the image back there
and runs `docker load`. A one-layer change on a 155 MB image sent 20 MB, against 53.8
MB whole (docs/spikes.md). It needs only Docker and `tar` on the server: the VPS has
no `rsync`, and no sudo to install it.

A project's own build (`builder.before`) runs here too, so the server never compiles
or builds. `prune` removes blobs no kept image uses. `registry` in a Kamal file is
read and ignored with a notice. A registry would only pay with several servers.

## Config

`config/deploy.yml` with the same names as Kamal, so a project moves with little
or no change; the parser takes what the table above lists and **refuses an unknown
option by name** rather than ignoring it. Additions, all optional: `builder.before`,
`drain_timeout`, `cpus`, `memory`.

- **YAML:** std has none, so a small parser for the subset in use: maps, lists,
  scalars, comments; no anchors. Its own tests, against the eight real files.
- **ERB:** not supported and refused by line; the real files have it only in
  comments.
- **Secrets:** `.kamal/secrets` read as is, `$(...)` run through `sh`, so existing
  files work unchanged. Never logged; the config dump redacts them.
- **Labels:** kept on the container, so the orbitx TCP router (`autocgi`) keeps
  working if that server has a Traefik with the Docker provider.
- **SSH:** the system's `ssh` as a child process, with connection sharing
  (`ControlMaster`), rather than an SSH library in Zig: keys, agent and
  `~/.ssh/config` work as they already do. Remote arguments are quoted per word;
  the game deploy's lost-arguments bug came from exactly that.

Multi-host and multi-role: the config shape allows them, the first version refuses
more than one of either with a clear message.

## Games

Not in the core. Cowshed offers one generic thing: `pre_switch` and `post_switch`
hooks, and `drain_timeout`. The rest belongs to the engine and the game:
- **Persistent world (Orbitville):** the old server saves state and tells clients
  to reconnect; they resume on the new one, 1-2 s of pause. The engine resumes a
  session only within one server process today; across two is new engine work.
- **Matches (Arena, Rally):** new matches on the new version; a long
  `drain_timeout` lets the old finish. How a server reports "empty" is to be
  decided.

## Migration

Order: first a game on the VPS, which already has Traefik and no kamal-proxy; then
a small project; OrbitX last.

A server with kamal-proxy has it holding 80/443, so moving means replacing it with
Traefik: a short cut for **every app on that server** (5 for one, 2 for another),
and certificates issued again. Plan a window; test `acme.json` persistence first.
Never done without the owner's go-ahead for that server.

Kamal's own `proxy` keys become Traefik routers. Accessories' containers keep
running as they are; Cowshed adopts them by name, it does not recreate a database.

## Spikes

Done: results and what they changed in `docs/spikes.md`.

## What the game deploys need beyond the above

Read in `tools/deploy.sh` of Orbitville and Arena:
- A project's own build (a Zig server, a web build, assets copied, a Dockerfile
  written): `builder.before`, a command that produces the context folder, run here.
- A check of the staged files before anything is sent (Orbitville): `pre_upload`.
- A refusal of uncommitted work, unless `--dirty`; the version is the short commit.
- `cmd` arguments per word, and `cpus` and `memory` as `docker run` limits.
- `stop` and `remove`.
- Health: both serve HTTP, so a path replaces waiting for a line in the logs.

## Decisions for the owner

1. The migration order above, and that OrbitX moves last.
2. Scope of the first version, proposed: `setup`, `deploy`, `rollback`,
   `versions`, `logs`, `exec`, `prune`, lock, audit, one host, one role.
   Accessories in the second, since a game needs none and OrbitX moves last.
