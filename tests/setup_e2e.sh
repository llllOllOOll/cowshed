#!/usr/bin/env bash
# `cowshed setup` through real SSH on a throwaway server (Docker in Docker):
# a new server, run twice, then one with a Traefik like the VPS's.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PORT=12222
NAME=cowshed-e2e-server
WORK=$(mktemp -d)
trap 'docker rm -f "$NAME" >/dev/null 2>&1 || true; rm -rf "$WORK"' EXIT

(cd "$ROOT" && zig build)
docker build -q -t cowshed-e2e-server "$ROOT/tests/server" >/dev/null

ssh-keygen -q -t ed25519 -N '' -f "$WORK/key"
# This server's host key is new each run: not for the user's known_hosts.
mkdir "$WORK/bin"
cat > "$WORK/bin/ssh" <<WRAP
#!/bin/sh
exec /usr/bin/ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ControlPath=$WORK/cm "\$@"
WRAP
chmod +x "$WORK/bin/ssh"
export PATH="$WORK/bin:$PATH"
export XDG_STATE_HOME="$WORK/state" # Logs of this run, not the user's

docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --privileged --name "$NAME" -p "127.0.0.1:$PORT:22" -e DOCKER_TLS_CERTDIR= cowshed-e2e-server >/dev/null
for _ in $(seq 60); do
	docker exec "$NAME" docker version >/dev/null 2>&1 && break
	sleep 1
done
docker exec -i "$NAME" sh -c "mkdir -p /root/.ssh && chmod 700 /root/.ssh && cat > /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys" < "$WORK/key.pub"

config() {
	cat > "$WORK/deploy.yml" <<YAML
service: e2e
image: e2e
servers:
  - 127.0.0.1
ssh:
  user: root
  port: $PORT
  keys:
    - $WORK/key
proxy:
  host: e2e.example
  ssl: true
  acme_email: test@example.com
YAML
}
config
C=("$ROOT/zig-out/bin/cowshed" setup -c "$WORK/deploy.yml")
inside() { docker exec "$NAME" "$@"; }
fail() { echo "FAILED: $*"; exit 1; }

echo "== a new server, dry run"
"${C[@]}" --dry-run
[ -z "$(inside docker ps -aq)" ] || fail "a dry run made a container"
inside test ! -e /root/.cowshed || fail "a dry run made folders"

echo "== a new server"
"${C[@]}"
[ "$(inside docker inspect -f '{{.State.Running}}' cowshed-traefik)" = true ] || fail "our Traefik is not running"
first=$(inside docker inspect -f '{{.Id}}' cowshed-traefik)
inside test -d /root/.cowshed/blobs || fail "no blobs folder"
inside wget -qO- http://127.0.0.1:80/ 2>&1 | grep -q 404 || true

echo "== again: the same container"
"${C[@]}"
[ "$first" = "$(inside docker inspect -f '{{.Id}}' cowshed-traefik)" ] || fail "the second run replaced it"

echo "== our Traefik stopped: started again"
inside docker stop cowshed-traefik >/dev/null
"${C[@]}"
[ "$first" = "$(inside docker inspect -f '{{.Id}}' cowshed-traefik)" ] || fail "it was replaced, not started"
[ "$(inside docker inspect -f '{{.State.Running}}' cowshed-traefik)" = true ] || fail "it was not started"

echo "== a Traefik like the VPS's: used, and nothing added"
inside docker rm -f cowshed-traefik >/dev/null
inside docker network create network_public >/dev/null
inside mkdir -p /vps/config
inside docker run -d --name traefik --network network_public -p 80:80 -p 443:443 \
	-v /vps/config:/etc/traefik traefik:3.6.6 \
	--api.insecure=true --entrypoints.web.address=:80 --entrypoints.websecure.address=:443 \
	--providers.file.directory=/etc/traefik \
	--certificatesresolvers.letsencrypt.acme.email=a@b.example \
	--certificatesresolvers.letsencrypt.acme.storage=/tmp/acme.json \
	--certificatesresolvers.letsencrypt.acme.httpchallenge.entrypoint=web >/dev/null
sleep 1
"${C[@]}" | tee "$WORK/out"
grep -q "network network_public" "$WORK/out" || fail "did not read the network"
grep -q "resolver letsencrypt" "$WORK/out" || fail "did not read the resolver"
[ "$(inside docker ps -q | wc -l)" = 1 ] || fail "started something else"

echo "== a Traefik set up by a file, with no routes folder: read, and left alone"
inside docker rm -f traefik >/dev/null
inside mkdir -p /byfile/routes
docker exec -i "$NAME" sh -c 'cat > /byfile/traefik.yml' <<'YAML'
entryPoints:
  http:
    address: ":80"
  https:
    address: ":443"
providers:
  docker:
    exposedByDefault: false
certificatesResolvers:
  letsencrypt:
    acme:
      email: file-secret@b.example
      storage: /tmp/acme.json
      httpChallenge:
        entryPoint: http
YAML
inside docker run -d --name traefik --network network_public -p 80:80 -p 443:443 \
	-v /byfile/traefik.yml:/traefik.yml:ro traefik:3.6.6 traefik >/dev/null
sleep 1
before=$(inside docker inspect -f '{{.Id}} {{.State.StartedAt}}' traefik)
if "${C[@]}" > "$WORK/out"; then cat "$WORK/out"; fail "it should have stopped"; fi
grep -q "no routes folder" "$WORK/out" || { cat "$WORK/out"; fail "wrong reason"; }
if grep -q "file-secret" "$WORK/out"; then fail "it showed the file's contents"; fi
[ "$before" = "$(inside docker inspect -f '{{.Id}} {{.State.StartedAt}}' traefik)" ] || fail "it touched Traefik"

echo "== the same file with a routes folder: used, and nothing added"
inside docker rm -f traefik >/dev/null
inside sh -c 'sed -i "s|^providers:|providers:\n  file:\n    directory: /routes|" /byfile/traefik.yml'
inside docker run -d --name traefik --network network_public -p 80:80 -p 443:443 \
	-v /byfile/traefik.yml:/traefik.yml:ro -v /byfile/routes:/routes traefik:3.6.6 traefik >/dev/null
sleep 1
before=$(inside docker inspect -f '{{.Id}} {{.State.StartedAt}}' traefik)
"${C[@]}" | tee "$WORK/out"
grep -q "routes /routes" "$WORK/out" || fail "did not read the routes folder"
grep -q "entrypoint https" "$WORK/out" || fail "did not read the entrypoint"
grep -q "resolver letsencrypt" "$WORK/out" || fail "did not read the resolver"
if grep -q "file-secret" "$WORK/out"; then fail "it showed the file's contents"; fi
[ "$before" = "$(inside docker inspect -f '{{.Id}} {{.State.StartedAt}}' traefik)" ] || fail "it touched Traefik"
[ "$(inside docker ps -q | wc -l)" = 1 ] || fail "started something else"

echo "== a program on port 443, and no Traefik: stops, starts nothing"
inside docker rm -f traefik >/dev/null
inside sh -c 'nohup nc -lk -p 443 >/dev/null 2>&1 & echo started' >/dev/null
sleep 1
if "${C[@]}" > "$WORK/out"; then cat "$WORK/out"; fail "it should have stopped"; fi
grep -q "listens on port 443" "$WORK/out" || { cat "$WORK/out"; fail "wrong reason"; }
[ -z "$(inside docker ps -q)" ] || fail "started something"

echo "e2e passed"
