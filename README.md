# Cowshed

Cowshed deploys Docker containers to a server over SSH, as one Zig binary. The
server needs nothing of Cowshed's: no agent, no panel and no proxy of its own.

**Status:** early. Every command is tested on a throwaway server, and `setup` and
`deploy` have run on real ones, and so have `proxy adopt`, a first certificate, a volume and a
rollback, beside other apps. Using it, for people and
coding agents: [usage](docs/usage.md), [commands](docs/commands.md),
[configuration](docs/configuration.md). How it works: [design](docs/design.md).

## How it works

- **Traffic:** Traefik is the proxy. Cowshed uses the one already on the server,
  or installs one on a new server during `cowshed setup`.
- **Versions:** one container per version, so a rollback takes seconds and needs
  no build.
- **Switching:** the new version starts beside the old one and must pass a health
  check before it gets traffic. If it fails, the old one keeps serving.
- **Images:** built on your machine from a clean copy of what is committed, with no
  registry. Only the layers the server lacks are sent.
- **Safety:** a lock refuses two deploys at once, and a log on the server records
  who deployed what.

## Installing

On Linux or macOS (x86_64 or aarch64), the latest release, checked against its SHA-256:

```bash
curl -fsSL https://raw.githubusercontent.com/llllOllOOll/cowshed/main/scripts/install.sh | bash
cowshed update   # later: the newest release, the same way
```

It goes to `/usr/local/bin`, with sudo when needed; `COWSHED_INSTALL_DIR` puts it elsewhere.
Only your machine needs it, never the server.

## Starting a project

```bash
cowshed init --host my-server --domain app.example.com  # Writes the config, on this machine
cowshed check --remote                                   # Reads it, reaches the server
cowshed setup --dry-run                                  # Says what setup would do
cowshed setup && cowshed deploy
```

If the server has a Traefik with no routes folder, `setup` stops and says so.
`cowshed proxy adopt` shows what would change; with `--yes` it does it, cutting every
app behind that Traefik for some seconds, so that is the server owner's call.

## Build

Needs Zig 0.17.

```bash
zig build            # zig-out/bin/cowshed, whose version ends in -dev
zig build test       # unit tests
scripts/check.sh     # everything a commit must pass
```

A release is a tag `vX.Y.Z` on a commit whose `build.zig.zon` says `X.Y.Z`: GitHub then
runs the checks and publishes a binary per system with their `SHA256SUMS`.
