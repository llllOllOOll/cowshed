#!/usr/bin/env bash
# `cowshed proxy adopt` through real SSH on a throwaway server (Docker in Docker): a
# Traefik owned by another app's Compose project, with that app behind it. Then a
# Cowshed app deployed beside it.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SSH_PORT=12224
NAME=cowshed-e2e-proxy
WORK=$(mktemp -d)
cleanup() {
	docker rm -f "$NAME" >/dev/null 2>&1 || true
	docker images --format '{{.Repository}}:{{.Tag}}' e2e-beside | xargs -r docker rmi >/dev/null 2>&1 || true
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
export XDG_STATE_HOME="$WORK/state" # Logs of this run, not the user's

docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --privileged --name "$NAME" -p "127.0.0.1:$SSH_PORT:22" -e DOCKER_TLS_CERTDIR= cowshed-e2e-server >/dev/null
for _ in $(seq 60); do
	docker exec "$NAME" docker version >/dev/null 2>&1 && break
	sleep 1
done
docker exec -i "$NAME" sh -c "mkdir -p /root/.ssh && chmod 700 /root/.ssh && cat > /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys" < "$WORK/key.pub"

inside() { docker exec "$NAME" "$@"; }
fail() { echo "FAILED: $*"; exit 1; }

docker exec -i "$NAME" sh -c 'mkdir -p /opt/other/traefik && cat > /opt/other/traefik/traefik.yml' <<'YAML'
# The owner's comment
api:
  dashboard: true
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
      storage: /acme.json
      httpChallenge:
        entryPoint: http
YAML
docker exec -i "$NAME" sh -c 'cat > /opt/other/docker-compose.yml' <<'YAML'
# The owner's comment on the file
networks:
  web:
    external: true
services:
  traefik:
    image: traefik:3.6.6
    container_name: traefik
    restart: unless-stopped
    networks:
      - web
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./traefik/traefik.yml:/traefik.yml:ro
      - ./traefik/acme.json:/acme.json
  other:
    image: traefik/whoami
    container_name: other
    networks:
      - web
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.other.rule=Host(`other.example`)"
      - "traefik.http.routers.other.entrypoints=http"
      - "traefik.http.services.other.loadbalancer.server.port=80"
YAML
inside sh -c 'printf "{\"kept\":true}" > /opt/other/traefik/acme.json && chmod 600 /opt/other/traefik/acme.json'
inside docker network create web >/dev/null
inside sh -c 'cd /opt/other && docker compose up -d --quiet-pull' >/dev/null 2>&1
other_app() { inside curl -s -o /dev/null -w '%{http_code}' -H 'Host: other.example' http://127.0.0.1/ || true; }
for _ in $(seq 30); do [ "$(other_app)" = 200 ] && break; sleep 1; done
[ "$(other_app)" = 200 ] || fail "the other app does not answer before anything"

APP="$WORK/app"
mkdir -p "$APP/config"
cp "$ROOT/tests/app/app.py" "$ROOT/tests/app/Dockerfile" "$APP/"
echo one > "$APP/version.txt"
cat > "$APP/config/deploy.yml" <<YAML
service: beside
image: e2e-beside
servers:
  - 127.0.0.1
ssh:
  user: root
  port: $SSH_PORT
  keys:
    - $WORK/key
proxy:
  host: beside.example
  app_port: 8000
deploy_timeout: 8
drain_timeout: 2
YAML
git -C "$APP" init -q
git -C "$APP" config user.email e2e@example.com
git -C "$APP" config user.name e2e-tester
git -C "$APP" add -A
git -C "$APP" commit -qm one
cowshed() { (cd "$APP" && "$ROOT/zig-out/bin/cowshed" "$@"); }
files() { inside sha256sum /opt/other/docker-compose.yml /opt/other/traefik/traefik.yml /opt/other/traefik/acme.json; }
traefik_id() { inside docker inspect -f '{{.Id}}' traefik; }
other_id() { inside docker inspect -f '{{.Id}}' other; }

echo "== setup stops, and says what to do"
if cowshed setup > "$WORK/out"; then cat "$WORK/out"; fail "setup should have stopped"; fi
grep -q "cowshed proxy adopt" "$WORK/out" || { cat "$WORK/out"; fail "setup did not name the way out"; }

before_files=$(files)
before_traefik=$(traefik_id)
before_other=$(other_id)

echo "== the plan: says it all, changes nothing"
cowshed proxy adopt | tee "$WORK/out"
grep -q "Run it again with" "$WORK/out" || fail "no plan"
if grep -q file-secret "$WORK/out"; then fail "it showed the settings"; fi
[ "$before_files" = "$(files)" ] || fail "the plan changed files"
[ "$before_traefik" = "$(traefik_id)" ] || fail "the plan touched Traefik"
inside test ! -e /opt/other/traefik/cowshed-routes || fail "the plan made a folder"

echo "== settings Traefik refuses: found before any cut"
inside cp /opt/other/traefik/traefik.yml /tmp/saved.yml
inside sh -c 'printf "log:\n  level: [nonsense\n" >> /opt/other/traefik/traefik.yml'
if cowshed proxy adopt --yes > "$WORK/out"; then cat "$WORK/out"; fail "it should have stopped"; fi
grep -q "Traefik and its files are as they were" "$WORK/out" || { cat "$WORK/out"; fail "wrong reason"; }
[ "$before_traefik" = "$(traefik_id)" ] || fail "it touched Traefik"
[ "$(other_app)" = 200 ] || fail "the other app stopped answering"
[ -z "$(inside docker ps -aq --filter name=cowshed-adopt-test)" ] || fail "the test container stayed"
inside sh -c 'ls /opt/other/traefik/*.cowshed-new /opt/other/*.cowshed-new 2>/dev/null' && fail "staged files stayed"
inside cp /tmp/saved.yml /opt/other/traefik/traefik.yml
inside sh -c 'rm -rf /root/.cowshed/backups'

echo "== with --yes, under traffic"
inside sh -c 'nohup sh -c "while [ ! -e /tmp/stop ]; do c=\$(curl -s -o /dev/null --max-time 1 -w \"%{http_code}\" -H \"Host: other.example\" http://127.0.0.1/) || c=000; echo \"\$(date +%s) \$c\" >> /tmp/codes; sleep 0.1; done" >/dev/null 2>&1 &'
sleep 2
cowshed proxy adopt --yes | tee "$WORK/out"
inside touch /tmp/stop
sleep 1
grep -q "^adopted:" "$WORK/out" || fail "not adopted"
grep -q "^check: other.example answers 200" "$WORK/out" || fail "the check was not shown"
log=$(sed -n 's/^log: //p' "$WORK/out")
grep -q "^adopted:" "$log" || fail "the local log lacks it"
if grep -q file-secret "$WORK/out"; then fail "it showed the settings"; fi
first=$(inside sh -c 'grep -v " 200$" /tmp/codes | head -1 | cut -d" " -f1')
last=$(inside sh -c 'grep -v " 200$" /tmp/codes | tail -1 | cut -d" " -f1')
echo "the other app was out for about $((last - first + 1)) s"
[ "$(other_app)" = 200 ] || fail "the other app does not answer after"
[ "$before_traefik" != "$(traefik_id)" ] || fail "Traefik was not recreated"
[ "$before_other" = "$(other_id)" ] || fail "the other app was recreated"
inside grep -q '"kept":true' /opt/other/traefik/acme.json || fail "the certificates' file changed"
inside grep -q "The owner's comment" /opt/other/traefik/traefik.yml || fail "the owner's comment went"
inside grep -q "The owner's comment on the file" /opt/other/docker-compose.yml || fail "the owner's comment went"
inside sh -c 'grep -q "\"kept\":true" /root/.cowshed/backups/traefik-*/mount-*' || fail "the certificates were not backed up"
inside sh -c 'cd /opt/other && docker compose ps traefik -q' | grep -q . || fail "Compose lost it"
inside sh -c 'cd /opt/other && docker compose up -d --dry-run 2>&1' | grep -qi "recreate" && fail "Compose wants to change something"
[ "$(inside sh -c 'stat -c %a /root/.cowshed/backups/traefik-*')" = 700 ] || fail "the backup is readable by others"

echo "== again: nothing to do"
after_traefik=$(traefik_id)
cowshed proxy adopt --yes | tee "$WORK/out"
grep -q "nothing to do" "$WORK/out" || fail "it did more"
[ "$after_traefik" = "$(traefik_id)" ] || fail "it touched Traefik again"

echo "== a Cowshed app beside the other one"
cowshed setup --dry-run | tee "$WORK/out"
grep -q "routes /cowshed-routes" "$WORK/out" || fail "setup does not see the folder"
if grep -q "API is off" "$WORK/out"; then fail "setup sees no API"; fi
cowshed setup >/dev/null
cowshed deploy > "$WORK/out" || { cat "$WORK/out"; fail "the deploy failed"; }
grep -q "traffic goes to" "$WORK/out" || { cat "$WORK/out"; fail "the switch was not confirmed"; }
[ "$(inside curl -s -H 'Host: beside.example' http://127.0.0.1/)" = one ] || fail "the new app does not answer"
[ "$(other_app)" = 200 ] || fail "the other app stopped answering"
[ "$after_traefik" = "$(traefik_id)" ] || fail "the deploy touched Traefik"

echo "e2e passed"
