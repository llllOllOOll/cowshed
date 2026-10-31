# Cowshed

Cowshed deploys Docker containers to a server over SSH, as one Zig binary. The
server needs nothing of Cowshed's: no agent, no panel and no proxy of its own.

**Status:** early. Every command is tested on a throwaway server, and `setup` and
`deploy` have run on a real one, for one app. The plan is in [BACKLOG.md](BACKLOG.md). Using it: [commands](docs/commands.md),
[configuration](docs/configuration.md). How it works: [design](docs/design.md).

## How it will work

- **Traffic:** Traefik is the proxy. Cowshed uses the one already on the server,
  or installs one on a new server during `cowshed setup`.
- **Versions:** one container per version, so a rollback takes seconds and needs
  no build.
- **Switching:** the new version starts beside the old one and must pass a health
  check before it gets traffic. If it fails, the old one keeps serving.
- **Images:** built on your machine, with no registry. Only the layers the server
  lacks are sent.
- **Safety:** a lock refuses two deploys at once, and a log on the server records
  who deployed what.

## Build

Needs Zig 0.17.

```bash
zig build            # zig-out/bin/cowshed
zig build test       # unit tests
scripts/check.sh     # everything a commit must pass
```
