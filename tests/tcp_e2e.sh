#!/usr/bin/env bash
# Raw TCP through Cowshed's own Traefik, on real SSH and a throwaway server (Docker in
# Docker): a port of its own, switched with the version, its connections drained, and a
# Traefik without that port refused, untouched.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SSH_PORT=12224
WEB_PORT=18092
TCP_PORT=19000
NAME=cowshed-e2e-tcp
WORK=$(mktemp -d)
cleanup() {
	[ -n "${hold:-}" ] && kill "$hold" 2>/dev/null || true
	docker rm -f "$NAME" >/dev/null 2>&1 || true
	docker images --format '{{.Repository}}:{{.Tag}}' tcp-app | xargs -r docker rmi >/dev/null 2>&1 || true
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
docker run -d --privileged --name "$NAME" -p "127.0.0.1:$SSH_PORT:22" -p "127.0.0.1:$WEB_PORT:80" -p "127.0.0.1:$TCP_PORT:9000" -e DOCKER_TLS_CERTDIR= cowshed-e2e-server >/dev/null
for _ in $(seq 60); do
	docker exec "$NAME" docker version >/dev/null 2>&1 && break
	sleep 1
done
docker exec -i "$NAME" sh -c "mkdir -p /root/.ssh && chmod 700 /root/.ssh && cat > /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys" < "$WORK/key.pub"

APP="$WORK/app"
mkdir -p "$APP/config"
cp "$ROOT/tests/app/app.py" "$ROOT/tests/app/Dockerfile" "$APP/"
cat > "$APP/config/deploy.yml" <<YAML
service: tcp
image: tcp-app
servers:
  - 127.0.0.1
ssh:
  user: root
  port: $SSH_PORT
  keys:
    - $WORK/key
proxy:
  host: tcp.example
  app_port: 8000
  tcp:
    - 9000
deploy_timeout: 8
drain_timeout: 3
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
# The first line a new TCP connection gets.
first_line() {
	python3 -c 'import socket, sys
s = socket.create_connection(("127.0.0.1", int(sys.argv[1])), 5)
print(s.makefile().readline().strip())' "$TCP_PORT"
}
# Keeps a connection, writing each line, then `closed` when the far end ends it.
cat > "$WORK/hold.py" <<'PY'
import socket, sys
s = socket.create_connection(("127.0.0.1", int(sys.argv[1])), 5)
with open(sys.argv[2], "a") as out:
    for line in s.makefile():
        out.write(line)
        out.flush()
    out.write("closed\n")
PY

echo "== setup: our Traefik with the raw TCP port"
cowshed setup | tee "$WORK/out"
grep -q "on 80, 443 and 9000" "$WORK/out" || fail "it did not say the TCP port"
inside docker inspect -f '{{json .Args}}' cowshed-traefik | grep -q 'entrypoints.tcp-9000.address=:9000' || fail "no TCP entrypoint"

echo "== a first version over raw TCP"
commit one
cowshed deploy > "$WORK/out" || { cat "$WORK/out"; fail "the first deploy failed"; }
[ "$(first_line)" = one ] || fail "TCP does not reach one: $(first_line)"

echo "== a new version: new connections to it, the old one's drained"
python3 "$WORK/hold.py" "$TCP_PORT" "$WORK/held" &
hold=$!
sleep 1
grep -qx one "$WORK/held" || fail "the held connection got nothing"
commit two
cowshed deploy | tee "$WORK/out" | grep -E '^(switch|drain|old|deployed)'
[ "$(first_line)" = two ] || fail "TCP does not reach two: $(first_line)"
grep -q "drain: 1 open" "$WORK/out" || fail "the held connection was not counted"
for _ in $(seq 20); do grep -qx closed "$WORK/held" && break; sleep 0.5; done
grep -qx closed "$WORK/held" || fail "the held connection was never ended"
grep -qx two "$WORK/held" && fail "the held connection switched mid-way"
hold=

echo "== rollback: TCP back with it"
cowshed rollback "$(git -C "$APP" rev-parse --short HEAD~1)" > "$WORK/out" || { cat "$WORK/out"; fail "the rollback failed"; }
[ "$(first_line)" = one ] || fail "TCP not back to one: $(first_line)"

echo "== a port Traefik has no entrypoint for: refused, Traefik untouched"
id=$(inside docker inspect -f '{{.Id}}' cowshed-traefik)
sed -i 's/    - 9000/    - 9000\n    - 9001/' "$APP/config/deploy.yml"
commit three
if cowshed deploy > "$WORK/out"; then fail "deployed without an entrypoint"; fi
grep -q "has no entrypoint on it" "$WORK/out" || fail "wrong reason: $(cat "$WORK/out")"
[ "$(inside docker inspect -f '{{.Id}}' cowshed-traefik)" = "$id" ] || fail "Traefik was recreated"
[ "$(first_line)" = one ] || fail "what ran was touched"

echo "e2e passed"
