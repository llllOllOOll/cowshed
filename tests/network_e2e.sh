#!/usr/bin/env bash
# `network: container:<name>` through real SSH on a throwaway server (Docker in Docker):
# the app in another container's network, refused while that one is down, switched
# under traffic with the port shared, an app that cannot share it refused with the old
# one serving, that container made again: seen by `check --remote`, mended by a deploy,
# and a route through Traefik to that container's name, switched under traffic.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SSH_PORT=12225
WEB_PORT=18093
NAME=cowshed-e2e-network
WORK=$(mktemp -d)
cleanup() {
	docker rm -f "$NAME" >/dev/null 2>&1 || true
	docker images --format '{{.Repository}}:{{.Tag}}' net-app | xargs -r docker rmi >/dev/null 2>&1 || true
	rm -rf "$WORK"
}
trap cleanup EXIT

(cd "$ROOT" && zig build)
docker build -q -t cowshed-e2e-server "$ROOT/tests/server" >/dev/null
ssh-keygen -q -t ed25519 -N '' -f "$WORK/key"
mkdir "$WORK/bin"
cat > "$WORK/bin/ssh" <<WRAP
#!/bin/sh
exec /usr/bin/ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ControlPath=$WORK/cm "\$@"
WRAP
chmod +x "$WORK/bin/ssh"
export PATH="$WORK/bin:$PATH"
export XDG_CACHE_HOME="$WORK/cache"
export XDG_STATE_HOME="$WORK/state"

docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --privileged --name "$NAME" -p "127.0.0.1:$SSH_PORT:22" -p "127.0.0.1:$WEB_PORT:80" -e DOCKER_TLS_CERTDIR= cowshed-e2e-server >/dev/null
for _ in $(seq 60); do
	docker exec "$NAME" docker version >/dev/null 2>&1 && break
	sleep 1
done
docker exec -i "$NAME" sh -c "mkdir -p /root/.ssh && chmod 700 /root/.ssh && cat > /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys" < "$WORK/key.pub"

APP="$WORK/app"
mkdir -p "$APP/config"
# Its version on 127.0.0.1:8000 of whatever network it is in; the port shared with
# SO_REUSEPORT unless `reuse.txt` says no.
cat > "$APP/app.py" <<'PY'
import http.server, pathlib, signal, sys
VERSION = pathlib.Path("/app/version.txt").read_text().strip()
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass
    def do_GET(self):
        body = VERSION.encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
class Server(http.server.ThreadingHTTPServer):
    allow_reuse_port = pathlib.Path("/app/reuse.txt").read_text().strip() == "yes"
signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
Server(("0.0.0.0", 8000), Handler).serve_forever()
PY
cat > "$APP/Dockerfile" <<'DOCKER'
FROM python:3-alpine
COPY app.py version.txt reuse.txt /app/
CMD ["python", "/app/app.py"]
DOCKER
echo yes > "$APP/reuse.txt"
cat > "$APP/config/deploy.yml" <<YAML
service: net
image: net-app
servers:
  - 127.0.0.1
ssh:
  user: root
  port: $SSH_PORT
  keys:
    - $WORK/key
network: container:vpn
deploy_timeout: 5
YAML
git -C "$APP" init -q
git -C "$APP" config user.email e2e@example.com
git -C "$APP" config user.name e2e-tester

cowshed() { (cd "$APP" && "$ROOT/zig-out/bin/cowshed" "$@"); }
inside() { docker exec "$NAME" "$@"; }
fail() { echo "FAILED: $*"; exit 1; }
commit() {
	printf '%s\n' "$1" > "$APP/version.txt"
	git -C "$APP" add -A
	git -C "$APP" commit -qm "$1"
}
# What answers on 127.0.0.1:8000 inside the vpn container's network.
ask() { inside docker exec vpn wget -qO- -T 2 http://127.0.0.1:8000/ 2>/dev/null || true; }
vpn() { inside docker run -d --name vpn alpine:3 sleep 3600 > /dev/null; }

echo "== that container not there: refused, nothing started"
commit one
if cowshed deploy > "$WORK/out"; then fail "deployed with no container to share"; fi
grep -q "the app shares the network of \`vpn\`, which is not running" "$WORK/out" || fail "wrong reason: $(cat "$WORK/out")"
inside docker ps -a --format '{{.Names}}' | grep -q '^net-web-' && fail "a version was started"

echo "== the first version: in vpn's network, and nothing published"
vpn
cowshed deploy > "$WORK/out" || { cat "$WORK/out"; fail "the deploy failed"; }
[ "$(ask)" = one ] || fail "not reached in vpn's network: $(ask)"
live=$(inside docker ps --filter label=service=net --format '{{.Names}}')
vpn_id=$(inside docker inspect -f '{{.Id}}' vpn)
[ "$(inside docker inspect -f '{{.HostConfig.NetworkMode}}' "$live")" = "container:$vpn_id" ] || fail "not in vpn's network"
[ -z "$(inside docker inspect -f '{{json .NetworkSettings.Ports}}' "$live" | tr -d '{}null')" ] || fail "a port was published"
inside docker network ls --format '{{.Name}}' | grep -qx 'container:vpn' && fail "a network was made"

echo "== exec: in the same network"
cowshed exec python -c 'import urllib.request; print(urllib.request.urlopen("http://127.0.0.1:8000/").read().decode())' > "$WORK/out" 2>&1 || true
grep -qx one "$WORK/out" || fail "exec is not in vpn's network: $(cat "$WORK/out")"

echo "== a second version under traffic: the port shared, every request answered"
commit two
inside docker exec -d vpn sh -c 'while [ ! -e /stop ]; do wget -qO- -T 2 http://127.0.0.1:8000/ || echo FAIL; echo; sleep 0.05; done > /log 2>&1'
cowshed deploy > "$WORK/out" || { cat "$WORK/out"; fail "the deploy failed"; }
sleep 1
inside docker exec vpn touch /stop
sleep 0.5
inside docker exec vpn cat /log > "$WORK/log"
[ "$(ask)" = two ] || fail "the new version does not answer: $(ask)"
grep -q '^one$' "$WORK/log" || fail "the old version was never asked: $(sort "$WORK/log" | uniq -c)"
grep -q '^two$' "$WORK/log" || fail "the new version was never asked"
failed=$(grep -c FAIL "$WORK/log" || true)
echo "   $(grep -c . "$WORK/log") answers, $failed failed"
[ "$failed" = 0 ] || fail "requests failed during the switch: $failed"
[ "$(inside docker ps --filter label=service=net --format '{{.Names}}' | wc -l)" = 1 ] || fail "the old version still runs"

echo "== an app that cannot share the port: refused, the old one serving"
echo no > "$APP/reuse.txt"
commit three
if cowshed deploy > "$WORK/out"; then fail "a version that cannot listen deployed"; fi
grep -q "died and was started again" "$WORK/out" || fail "wrong reason: $(tail -5 "$WORK/out")"
grep -qi "address in use" "$WORK/out" || fail "its logs did not say why: $(tail -5 "$WORK/out")"
[ "$(ask)" = two ] || fail "the old version stopped serving: $(ask)"
git -C "$APP" reset -q --hard HEAD~1

echo "== that container made again: seen by check --remote, mended by a deploy"
cowshed check --remote > "$WORK/out" || fail "check failed before: $(cat "$WORK/out")"
grep -q warning "$WORK/out" && fail "a warning with nothing wrong: $(cat "$WORK/out")"
inside docker rm -f vpn > /dev/null
vpn
[ -z "$(ask)" ] || fail "reached through a vpn made again, unexpectedly"
cowshed check --remote > "$WORK/out" || true
grep -q "is on the network of a \`vpn\` made again since" "$WORK/out" || fail "check did not see it: $(cat "$WORK/out")"
# Nothing changed in the app: what runs is out of reach all the same.
cowshed deploy > "$WORK/out" || { cat "$WORK/out"; fail "the deploy failed"; }
grep -q "nothing changed" "$WORK/out" && fail "taken for live: $(cat "$WORK/out")"
[ "$(ask)" = two ] || fail "not mended: $(ask)"
cowshed check --remote > "$WORK/out" || true
grep -q warning "$WORK/out" && fail "still warned: $(cat "$WORK/out")"

echo "== with a route: refused while that container is off Traefik's network"
cat >> "$APP/config/deploy.yml" <<'YAML'
proxy:
  host: net.example
  app_port: 8000
  healthcheck:
    path: /
YAML
git -C "$APP" commit -qam route
cowshed setup > "$WORK/out" || { cat "$WORK/out"; fail "setup failed"; }
commit five
if cowshed deploy > "$WORK/out"; then fail "deployed with that container off Traefik's network"; fi
grep -q "is not on Traefik's network \`cowshed\`" "$WORK/out" || fail "wrong reason: $(cat "$WORK/out")"
[ "$(ask)" = two ] || fail "the old version stopped serving: $(ask)"

echo "== put there in its own config: reached by its name, from inside and through Traefik"
inside docker network connect cowshed vpn
cowshed deploy > "$WORK/out" || { cat "$WORK/out"; fail "the deploy failed"; }
grep -q "switch: traffic goes to vpn" "$WORK/out" || fail "the route is not to vpn: $(cat "$WORK/out")"
reach() { curl -s -m 2 -H 'Host: net.example' "http://127.0.0.1:$WEB_PORT/" || true; }
[ "$(reach)" = five ] || fail "not reached through Traefik: $(reach)"
[ "$(ask)" = five ] || fail "not reached from inside: $(ask)"

echo "== a version under traffic through Traefik: every request answered"
commit six
( while [ ! -e "$WORK/stop" ]; do reach; echo; sleep 0.05; done > "$WORK/routed" ) &
loop=$!
cowshed deploy > "$WORK/out" || { cat "$WORK/out"; fail "the deploy failed"; }
grep -q "drain: none, the versions share one network" "$WORK/out" || fail "it drained: $(cat "$WORK/out")"
sleep 1
touch "$WORK/stop"
wait "$loop"
grep -q '^five$' "$WORK/routed" || fail "the old version was never asked"
grep -q '^six$' "$WORK/routed" || fail "the new version was never asked"
bad=$(grep -cvE '^(five|six)$' "$WORK/routed" || true)
echo "   $(grep -c . "$WORK/routed") answers, $bad failed"
[ "$bad" = 0 ] || fail "requests failed during the switch: $(grep -vE '^(five|six)$' "$WORK/routed" | sort | uniq -c)"
[ "$(reach)" = six ] || fail "the new version is not routed: $(reach)"

echo "e2e passed"
