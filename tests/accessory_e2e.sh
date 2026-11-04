#!/usr/bin/env bash
# `cowshed accessory` through real SSH on a throwaway server (Docker in Docker): a
# long-lived container with its secrets, files, directory and network, its life, what
# `remove` keeps, and a container of its name that is someone else's.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SSH_PORT=12223
WEB_PORT=18091
NAME=cowshed-e2e-accessory
WORK=$(mktemp -d)
cleanup() {
	docker rm -f "$NAME" >/dev/null 2>&1 || true
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

docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --privileged --name "$NAME" -p "127.0.0.1:$SSH_PORT:22" -p "127.0.0.1:$WEB_PORT:80" -e DOCKER_TLS_CERTDIR= cowshed-e2e-server >/dev/null
for _ in $(seq 60); do
	docker exec "$NAME" docker version >/dev/null 2>&1 && break
	sleep 1
done
docker exec -i "$NAME" sh -c "mkdir -p /root/.ssh && chmod 700 /root/.ssh && cat > /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys" < "$WORK/key.pub"

APP="$WORK/app"
mkdir -p "$APP/config/db" "$APP/.cowshed"
printf 'CREATE DATABASE second;\n' > "$APP/config/db/init.sql"
# The accessory: writes what it was given into its directory, then stays up.
cat > "$APP/config/deploy.yml" <<YAML
service: acc
image: acc-app
servers:
  - 127.0.0.1
ssh:
  user: root
  port: $SSH_PORT
  keys:
    - $WORK/key
networks:
  - acc-own
accessories:
  db:
    image: alpine:3
    cmd: sh -c 'echo "\$DB_PASSWORD" > /data/password; cat /init/init.sql > /data/init; date +%s%N > /data/booted; exec sleep 600'
    env:
      clear:
        DB_USER: app
      secret:
        - DB_PASSWORD
    files:
      - config/db/init.sql:/init/init.sql
    directories:
      - data:/data
  auth:
    image: busybox:1
    cmd: sh -c 'mkdir -p /www && echo "auth \$(date +%s%N)" > /www/index.html && exec httpd -f -p 8080 -h /www'
    proxy:
      host: auth.example
      app_port: 8080
      healthcheck:
        path: /
    boot_timeout: 20
YAML
cat > "$APP/.cowshed/secrets" <<'SECRETS'
DB_PASSWORD=$(printf 'hidden-db-password')
SECRETS

cowshed() { (cd "$APP" && "$ROOT/zig-out/bin/cowshed" "$@"); }
inside() { docker exec "$NAME" "$@"; }
fail() { echo "FAILED: $*"; exit 1; }
FOLDER=/root/.cowshed/accessories/acc-accessory-db

echo "== a container of its name that Cowshed did not make: refused, left as it is"
inside docker run -d --name acc-accessory-db alpine:3 sleep 600 > /dev/null
if cowshed accessory boot db > "$WORK/out"; then fail "boot took a foreign container"; fi
grep -q "is not an accessory of acc" "$WORK/out" || fail "wrong reason: $(cat "$WORK/out")"
if cowshed accessory reboot db > "$WORK/out"; then fail "reboot took a foreign container"; fi
if cowshed accessory remove db --yes > "$WORK/out"; then fail "remove took a foreign container"; fi
[ "$(inside docker inspect -f '{{.State.Running}} {{.Config.Image}}' acc-accessory-db)" = "true alpine:3" ] || fail "the foreign container was touched"
inside docker rm -f acc-accessory-db > /dev/null

echo "== boot: secrets, files, its directory and the project's network"
cowshed accessory boot db | tee "$WORK/out"
[ "$(inside docker inspect -f '{{.State.Running}}' acc-accessory-db)" = true ] || fail "it does not run"
[ "$(inside cat "$FOLDER/directories/data/password")" = hidden-db-password ] || fail "the secret did not arrive"
inside grep -q "CREATE DATABASE second" "$FOLDER/directories/data/init" || fail "the file did not arrive"
[ "$(inside docker exec acc-accessory-db printenv DB_USER)" = app ] || fail "a clear variable did not arrive"
[ "$(inside stat -c %a "$FOLDER/env")" = 600 ] || fail "the env file is not private"
inside docker inspect -f '{{json .NetworkSettings.Networks}}' acc-accessory-db | grep -q '"acc-own"' || fail "not on the project's network"
inside docker inspect -f '{{index .Config.Labels "accessory"}} {{index .Config.Labels "service"}}' acc-accessory-db | grep -qx 'acc ' || fail "wrong labels"
inside docker inspect -f '{{json .Args}} {{json .Config.Cmd}} {{json .HostConfig.Binds}}' acc-accessory-db | grep -q hidden && fail "a secret on a command line"
grep -q hidden "$WORK/out" && fail "a secret in the output"
if inside docker exec acc-accessory-db sh -c 'echo x > /init/init.sql' 2>/dev/null; then fail "a file sent is writable"; fi
inside grep -q "accessory db booted" /root/.cowshed/audit-acc.log || fail "not in the audit log"

echo "== boot again: left alone"
booted=$(inside cat "$FOLDER/directories/data/booted")
cowshed accessory boot db | grep -q "already runs" || fail "it did not say it runs"
[ "$(inside cat "$FOLDER/directories/data/booted")" = "$booted" ] || fail "it was started again"

echo "== logs, exec"
cowshed accessory exec db cat /data/init | grep -q "CREATE DATABASE second" || fail "exec did not run in it"
if cowshed accessory exec db sh -c 'exit 3' > "$WORK/out"; then fail "a failing exec passed"; fi
grep -q "exit code 3" "$WORK/out" || fail "no exit code"
cowshed accessory logs db --lines 5 > /dev/null || fail "logs failed"

echo "== stop and start: the same container"
id=$(inside docker inspect -f '{{.Id}}' acc-accessory-db)
cowshed accessory stop db
[ "$(inside docker inspect -f '{{.State.Running}}' acc-accessory-db)" = false ] || fail "it still runs"
if cowshed accessory boot db > "$WORK/out"; then fail "boot started a stopped one"; fi
grep -q "accessory start db" "$WORK/out" || fail "it did not say to start it"
cowshed accessory start db
[ "$(inside docker inspect -f '{{.Id}}' acc-accessory-db)" = "$id" ] || fail "start made another container"

echo "== reboot: the new settings, the data carried over, the old one gone"
id=$(inside docker inspect -f '{{.Id}}' acc-accessory-db)
sed -i 's/DB_USER: app/DB_USER: changed/' "$APP/config/deploy.yml"
cowshed accessory reboot db | tee "$WORK/out"
[ "$(inside docker exec acc-accessory-db printenv DB_USER)" = changed ] || fail "the new settings did not take"
[ "$(inside docker inspect -f '{{.Id}}' acc-accessory-db)" != "$id" ] || fail "not a new container"
if inside docker inspect acc-accessory-db-replaced > /dev/null 2>&1; then fail "the old one stayed"; fi
[ "$(inside cat "$FOLDER/directories/data/password")" = hidden-db-password ] || fail "the data did not carry over"
inside grep -q "accessory db rebooted" /root/.cowshed/audit-acc.log || fail "not in the audit log"

echo "== a reboot that fails: the old one back, running"
id=$(inside docker inspect -f '{{.Id}}' acc-accessory-db)
cp "$APP/config/deploy.yml" "$WORK/good.yml"
sed -i "s|exec sleep 600|echo broken reboot; exit 1|" "$APP/config/deploy.yml"
if cowshed accessory reboot db > "$WORK/out"; then fail "a broken reboot passed"; fi
grep -q "broken reboot" "$WORK/out" || fail "its logs were not shown"
grep -q "the old acc-accessory-db is back" "$WORK/out" || fail "wrong reason: $(cat "$WORK/out")"
[ "$(inside docker inspect -f '{{.Id}} {{.State.Running}}' acc-accessory-db)" = "$id true" ] || fail "the old one is not back and running"
if inside docker inspect acc-accessory-db-replaced > /dev/null 2>&1; then fail "a container set aside stayed"; fi
cp "$WORK/good.yml" "$APP/config/deploy.yml"

echo "== remove: only with --yes, its directory kept, and a boot finds it again"
if cowshed accessory remove db > "$WORK/out"; then fail "removed without --yes"; fi
grep -q "the directory data:/data stays" "$WORK/out" || fail "it did not say the directory stays"
inside docker inspect acc-accessory-db > /dev/null || fail "removed without --yes"
cowshed accessory remove db --yes
if inside docker inspect acc-accessory-db > /dev/null 2>&1; then fail "the container stayed"; fi
inside test ! -e "$FOLDER/env" || fail "the env file stayed"
inside test -s "$FOLDER/directories/data/password" || fail "the directory went"
inside docker network inspect acc-own > /dev/null || fail "the network went"
cowshed accessory boot db > /dev/null
[ "$(inside cat "$FOLDER/directories/data/password")" = hidden-db-password ] || fail "booting again failed"
cowshed accessory remove db --yes > /dev/null

echo "== a route: healthy through Traefik, then reachable by its host, across a reboot"
cowshed setup > /dev/null
cowshed accessory boot auth | tee "$WORK/out"
grep -q "health: acc-accessory-auth is healthy" "$WORK/out" || fail "its health was not asked"
reach() { curl -s -H 'Host: auth.example' "http://127.0.0.1:$WEB_PORT/"; }
first=$(reach)
case "$first" in auth\ *) ;; *) fail "not reachable by its host: $first" ;; esac
inside docker inspect -f '{{json .NetworkSettings.Networks}}' acc-accessory-auth | grep -q '"cowshed"' || fail "not on Traefik's network"
cowshed accessory reboot auth > "$WORK/out" || { cat "$WORK/out"; fail "the reboot failed"; }
second=$(reach)
case "$second" in auth\ *) ;; *) fail "not reachable after the reboot: $second" ;; esac
[ "$second" != "$first" ] || fail "the reboot did not serve a new container"
cowshed accessory remove auth --yes > "$WORK/out"
inside test ! -e /root/.cowshed/traefik/routes/cowshed-acc-accessory-auth.yml || fail "its route file stayed"
code=
for _ in $(seq 10); do
	code=$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: auth.example' "http://127.0.0.1:$WEB_PORT/")
	[ "$code" = 404 ] && break
	sleep 0.5
done
[ "$code" = 404 ] || fail "its route stayed: $code, $(cat "$WORK/out")"

echo "== one that exits at once: shown, removed, its directory kept"
sed -i "s|exec sleep 600|echo broken setting; exit 1|" "$APP/config/deploy.yml"
if cowshed accessory boot db > "$WORK/out"; then fail "a broken accessory passed"; fi
grep -q "broken setting" "$WORK/out" || fail "its logs were not shown"
grep -q "exited at once" "$WORK/out" || fail "wrong reason: $(cat "$WORK/out")"
if inside docker inspect acc-accessory-db > /dev/null 2>&1; then fail "the broken one stayed"; fi
inside test -s "$FOLDER/directories/data/password" || fail "the directory went"

echo "e2e passed"
