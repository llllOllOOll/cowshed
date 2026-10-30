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
- [ ] First real deploy: Arena
- [ ] Orbitville; then both `tools/deploy.sh` removed

## Second version

- [ ] Accessories (database, Keycloak)
- [ ] A small Kamal project moved, then OrbitX, last. Replacing kamal-proxy cuts
      every app on that server for a moment: needs the owner's go-ahead per server

## Open

- [ ] A large part being sent shows no progress of its own
- [ ] Installing Docker has run only against the fake: try it on a clean VM
- [ ] Our own Traefik's Let's Encrypt certificates: not issued in a test yet
- [ ] A Traefik set up by a static file or its environment: `setup` stops, read them
- [ ] A routes folder not writable from inside Traefik: the helper container
- [ ] Hooks for games: `pre_switch`, `post_switch`. `builder.before` covers the check before sending
- [ ] `logs` and `exec` give their output at the end: following logs needs streaming
      in the remote port
- [ ] HTTPS end to end: the e2e test runs plain HTTP
- [ ] Not tested yet: TLS and certificate issuing through a file route, and the whole
      flow on the VPS (the first Arena deploy is that test)
- [ ] Requests under way across a switch: only read in the source
- [ ] Where the orbitx-* projects without `.kamal/secrets` get their secrets
- [ ] How a game server reports "empty", for draining matches
