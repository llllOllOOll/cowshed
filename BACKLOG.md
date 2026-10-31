# Backlog

## First version: replace the games' `tools/deploy.sh`

- [x] Repository, layout, docs and checks
- [x] Spikes with a throwaway Traefik (`docs/spikes.md`)
- [x] Config: the YAML subset, validation, secrets
- [x] The `remote` port: `ssh` and a fake for tests
- [x] `check`: the config and the secrets' names; `--remote` reaches the server
- [x] `setup`: Docker, folders, Traefik if none, `--dry-run` (`tests/setup_e2e.sh`)
- [x] `deploy`: lock, image, new beside old, health, switch, confirm, drain, audit
      (`tests/deploy_e2e.sh`)
- [x] Sending an image: only the blobs the server lacks
- [x] `lock status`, `lock release`
- [x] `rollback`, `versions`, `logs`, `exec`, `prune`, `stop`, `remove`, `audit`
- [x] First real deploy: Arena, on the VPS (2026-10-30). HTTPS, the redirect and a
      WebSocket handshake checked from outside. It broke in the browser (`UnknownSystem`:
      the game behind the engine), fixed the same day; the owner confirmed it working
- [ ] Orbitville; then both `tools/deploy.sh` removed

- [x] A project in a monorepo: `branch` and `sources`, built from clean copies, skipped if
      nothing changed, what it was made from on the container and in the audit log
      (`tests/monorepo_e2e.sh`)

## Second version

- [ ] Accessories (database, Keycloak)
- [ ] A small project moved, then OrbitX, last. Replacing another proxy on a server cuts
      every app there for a moment: needs the owner's go-ahead per server

## Open

- [ ] A clean copy lacks what git ignores on the first deploy: a build needing it (Orbitville's
      assets?) must fetch it itself
- [ ] A page's own check before the switch: a health path proves the server, not that
      a game starts in the browser. Arena's first deploy passed it broken. A headless
      browser reading the console caught it (`chromium --headless`, `--enable-logging`)
- [ ] A server that ignores SIGTERM takes `docker stop`'s full 10 s (Arena's did: exit 137)
- [ ] A large part being sent shows no progress of its own
- [ ] Installing Docker has run only against the fake: try it on a clean VM
- [ ] Our own Traefik's Let's Encrypt certificates: not issued yet; the VPS's Traefik
      issued one through a file route
- [ ] A Traefik set up by a static file or its environment: `setup` stops, read them
- [ ] A routes folder not writable from inside Traefik: the helper container
- [ ] Hooks for games: `pre_switch`, `post_switch`. `builder.before` covers the check before sending
- [ ] `logs` and `exec` give their output at the end: following logs needs streaming
      in the remote port
- [ ] HTTPS end to end: the e2e test runs plain HTTP
- [ ] Requests under way across a switch: only read in the source
- [ ] Where the orbitx-* projects without a secrets file get their secrets
- [ ] How a game server reports "empty", for draining matches
