#!/usr/bin/env bash
# `cowshed deploy` through real SSH on a throwaway server (Docker in Docker), under
# traffic, with the failures that must leave the running version untouched.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SSH_PORT=12222
WEB_PORT=18090
NAME=cowshed-e2e-server
WORK=$(mktemp -d)
cleanup() {
	docker rm -f "$NAME" >/dev/null 2>&1 || true
	docker images --format '{{.Repository}}:{{.Tag}}' e2e-app | xargs -r docker rmi >/dev/null 2>&1 || true
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
export XDG_CACHE_HOME="$WORK/cache" # Clean copies of this run, not the user's
export XDG_STATE_HOME="$WORK/state" # Logs of this run, not the user's

docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --privileged --name "$NAME" -p "127.0.0.1:$SSH_PORT:22" -p "127.0.0.1:$WEB_PORT:80" -e DOCKER_TLS_CERTDIR= cowshed-e2e-server >/dev/null
for _ in $(seq 60); do
	docker exec "$NAME" docker version >/dev/null 2>&1 && break
	sleep 1
done
docker exec -i "$NAME" sh -c "mkdir -p /root/.ssh && chmod 700 /root/.ssh && cat > /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys" < "$WORK/key.pub"

APP="$WORK/app"
mkdir -p "$APP/config" "$APP/.cowshed"
cp "$ROOT/tests/app/app.py" "$ROOT/tests/app/Dockerfile" "$APP/"
cat > "$APP/config/deploy.yml" <<YAML
service: e2e
image: e2e-app
servers:
  - 127.0.0.1
ssh:
  user: root
  port: $SSH_PORT
  keys:
    - $WORK/key
proxy:
  host: e2e.example
  app_port: 8000
  healthcheck:
    path: /up
builder:
  before: echo "\$COWSHED_VERSION" > built.txt; ls -A > "$WORK/seen"
env:
  clear:
    MODE: test
  secret:
    - TOKEN
    - OTHER:FROM_ENV_VAR
volumes:
  - /srv/e2e-data:/data
deploy_timeout: 8
drain_timeout: 3
replaces: legacy
YAML
cat > "$APP/.cowshed/secrets" <<'SECRETS'
TOKEN=$(printf 'hidden-token-value')
FROM_ENV_VAR=$E2E_FROM_ENV
NOT_WANTED=$(exit 1)
SECRETS
export E2E_FROM_ENV=hidden-env-value
printf 'built.txt\n.cowshed\nignored.env\n' > "$APP/.gitignore"
git -C "$APP" init -q
git -C "$APP" config user.email e2e@example.com
git -C "$APP" config user.name e2e-tester

cowshed() { (cd "$APP" && "$ROOT/zig-out/bin/cowshed" "$@"); }
# Only what a command itself printed, its steps aside.
result() { cowshed "$@" | grep -v '^exec: running'; }
inside() { docker exec "$NAME" "$@"; }
fail() { echo "FAILED: $*"; exit 1; }
commit() {
	printf '%s\n' "$1" > "$APP/version.txt"
	git -C "$APP" add -A
	git -C "$APP" commit -qm "$1"
}
serving() { curl -s -H 'Host: e2e.example' "http://127.0.0.1:$WEB_PORT/"; }
live_containers() { inside docker ps --filter label=service=e2e --format '{{.Names}}' | sort | tr '\n' ' '; }

echo "== setup"
cowshed setup

echo "== no commit yet: refused"
if cowshed deploy > "$WORK/out"; then fail "deployed with no commit"; fi
grep -q "no commit yet" "$WORK/out" || fail "wrong reason: $(cat "$WORK/out")"

commit one
echo uncommitted > "$APP/version.txt"
echo new > "$APP/untracked.txt"
echo hidden > "$APP/ignored.env"

echo "== a first deploy, replacing a container from before, with only what is committed"
inside docker run -d --name legacy alpine sleep 600 >/dev/null
cowshed deploy | tee "$WORK/out" | grep -vE '^#|^$|^ *$' | cut -c1-120 | tail -12
[ "$(serving)" = one ] || fail "not serving one: $(serving)"
log=$(sed -n 's/^log: //p' "$WORK/out")
grep -q "^source:" "$log" || fail "the deploy's local log lacks it"
grep -q hidden "$log" && fail "a secret in the deploy's local log"
grep -q "not part of this deploy" "$WORK/out" || fail "it did not say what stayed out"
grep -q "new, not in git, left out: untracked.txt" "$WORK/out" || fail "it did not name the new file"
if grep -q "left out: ignored.env" "$WORK/out"; then fail "it named a file git ignores"; fi
grep -q "app.py" "$WORK/seen" || fail "the build saw no copy"
if grep -qE "untracked.txt|ignored.env" "$WORK/seen"; then fail "the build saw what is not committed"; fi
git -C "$APP" checkout -q -- version.txt
rm "$APP/untracked.txt" "$APP/ignored.env"
[ "$(inside docker inspect -f '{{.State.Running}}' legacy)" = false ] || fail "legacy still runs"
inside docker inspect legacy >/dev/null || fail "legacy was removed"
grep -q "from outside\|did not answer" "$WORK/out" || fail "no look from outside"

echo "== secrets: inside the container, nowhere else"
first=$(live_containers | tr -d ' ')
[ "$(inside docker exec "$first" printenv TOKEN)" = hidden-token-value ] || fail "TOKEN did not arrive"
[ "$(inside docker exec "$first" printenv OTHER)" = hidden-env-value ] || fail "the aliased secret did not arrive"
[ "$(inside docker exec "$first" printenv MODE)" = test ] || fail "a clear variable did not arrive"
[ "$(inside stat -c %a "/root/.cowshed/env/$first")" = 600 ] || fail "the env file is not private"
inside docker inspect -f '{{json .Args}} {{json .Config.Cmd}} {{json .HostConfig.Binds}}' "$first" | grep -q hidden && fail "a secret on a command line"
grep -q hidden "$WORK/out" && fail "a secret in the output"
inside cat /root/.cowshed/audit-e2e.log | grep -q hidden && fail "a secret in the audit log"

echo "== a new version under traffic"
commit two
python3 "$ROOT/tests/load.py" "$WEB_PORT" "$WORK/stop" > "$WORK/load" &
load=$!
sleep 1
cowshed deploy | tee "$WORK/out" | grep -E '^(deploy|proxy|lock|image|secrets|container|health|switch|drain|old|prune|deployed|stopped)' | cut -c1-120
touch "$WORK/stop"
wait "$load"
cat "$WORK/load" | cut -c1-200
grep -q CLEAN "$WORK/load" || fail "traffic saw errors"
grep -q "two" "$WORK/load" || fail "traffic never reached the new version"
grep -q "closed: True" "$WORK/load" || fail "the websocket outlived the old container"
[ "$(serving)" = two ] || fail "not serving two"
[ "$(live_containers | wc -w)" = 1 ] || fail "more than one running: $(live_containers)"

echo "== only a changed layer travels"
grep "of .* MB to send" "$WORK/out"
sent=$(grep -oE 'image: [0-9]+ of [0-9]+ MB to send' "$WORK/out" | grep -oE '^image: [0-9]+' | grep -oE '[0-9]+')
[ "$sent" -lt 5 ] || fail "sent $sent MB for a one-line change"

echo "== the new one failing its health: the old one serves on"
before=$(live_containers)
commit BROKEN
if cowshed deploy > "$WORK/out"; then fail "a broken version deployed"; fi
grep -q "did not pass its health check" "$WORK/out" || fail "wrong reason: $(tail -3 "$WORK/out")"
[ "$(serving)" = two ] || fail "the broken one serves"
[ "$(live_containers)" = "$before" ] || fail "containers changed: $(live_containers)"
inside docker ps -a --format '{{.Names}}' | grep -q "$(git -C "$APP" rev-parse --short HEAD)" && fail "the broken container was left"

echo "== the new one exiting at once"
commit three
printf 'FROM python:3-alpine\nCMD ["sh", "-c", "exit 3"]\n' > "$APP/Dockerfile"
git -C "$APP" add -A; git -C "$APP" commit -qm exit
start=$(date +%s)
if cowshed deploy > "$WORK/out"; then fail "an exiting version deployed"; fi
[ $(($(date +%s) - start)) -lt 60 ] || fail "too slow"
[ "$(serving)" = two ] || fail "the old one stopped serving"
cp "$ROOT/tests/app/Dockerfile" "$APP/"

echo "== a lock held: refused, and released by hand"
commit four
inside sh -c 'mkdir /root/.cowshed/locks/e2e && echo "someone else, version x" > /root/.cowshed/locks/e2e/details'
if cowshed deploy > "$WORK/out"; then fail "deployed through a lock"; fi
grep -q "someone else, version x" "$WORK/out" || fail "wrong reason: $(tail -2 "$WORK/out")"
cowshed lock status | grep -q "someone else" || fail "lock status"
cowshed lock release >/dev/null
[ "$(cowshed lock status)" = free ] || fail "not released"

echo "== a broken file in Traefik's folder: the route put back, the old one serves"
inside docker exec cowshed-traefik sh -c 'printf "http:\n  routers: [nonsense\n" > /etc/traefik/routes/broken.yml'
if cowshed deploy > "$WORK/out"; then fail "deployed past a broken file"; fi
grep -q "did not take the new route" "$WORK/out" || fail "wrong reason: $(tail -2 "$WORK/out")"
inside docker exec cowshed-traefik rm /etc/traefik/routes/broken.yml
sleep 3
[ "$(serving)" = two ] || fail "not serving two after the broken file: $(serving)"
[ "$(cowshed lock status)" = free ] || fail "the lock stayed"

echo "== the same version again: no gap, a new name"
cowshed deploy > "$WORK/out" || fail "deploy: $(tail -3 "$WORK/out")"
[ "$(serving)" = four ] || fail "not serving four"
python3 "$ROOT/tests/load.py" "$WEB_PORT" "$WORK/stop2" > "$WORK/load" &
load=$!
sleep 1
cowshed deploy --force > "$WORK/out" || fail "redeploy: $(tail -3 "$WORK/out")"
touch "$WORK/stop2"
wait "$load"
grep -q CLEAN "$WORK/load" || { cat "$WORK/load"; fail "a redeploy saw errors"; }
live_containers | grep -qE -- '-2 ' || fail "no second name: $(live_containers)"

echo "== prune: the last 3 stopped, and old blobs gone"
for v in five six seven eight; do
	commit "$v"
	cowshed deploy > "$WORK/out" || fail "deploy $v: $(tail -3 "$WORK/out")"
done
stopped=$(inside docker ps -a --filter label=service=e2e --filter status=exited -q | wc -l)
[ "$stopped" = 3 ] || fail "$stopped stopped containers"
[ "$(serving)" = eight ] || fail "not serving eight"
inside sh -c 'cat /root/.cowshed/images/e2e/*.blobs | sort -u > /tmp/k; for f in /root/.cowshed/blobs/sha256/*; do grep -qx "${f##*/}" /tmp/k || echo stray; done' | grep -q stray && fail "stray blobs"
inside sh -c 'for d in $(cat /root/.cowshed/images/e2e/*.blobs | sort -u); do test -e /root/.cowshed/blobs/sha256/$d || echo lost; done' | grep -q lost && fail "lost blobs"

echo "== versions"
cowshed versions | tee "$WORK/versions" | cut -c1-60
grep -q "^live" "$WORK/versions" || fail "nothing marked live"
grep -qE "^live.* 20[0-9]{2}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}" "$WORK/versions" || fail "no date in versions"
target=$(grep -v "^live" "$WORK/versions" | head -1 | awk '{print $1}')

echo "== rollback under traffic: no build, seconds"
rm -f "$WORK/stop3"
python3 "$ROOT/tests/load.py" "$WEB_PORT" "$WORK/stop3" > "$WORK/load" &
load=$!
sleep 1
start=$(date +%s)
cowshed rollback "$target" | grep -E '^(container|health|switch|drain|old|rolled|stopped)' | cut -c1-100
echo "rollback took $(($(date +%s) - start)) s"
touch "$WORK/stop3"
wait "$load"
grep -q CLEAN "$WORK/load" || { cat "$WORK/load"; fail "a rollback saw errors"; }
[ "$(serving)" = seven ] || fail "not serving seven after the rollback: $(serving)"
if cowshed rollback "$target" > "$WORK/out"; then fail "rolled back to what is live"; fi
grep -q "already live" "$WORK/out" || fail "wrong reason"
if cowshed rollback nothing > "$WORK/out"; then fail "rolled back to nothing"; fi

echo "== logs, exec"
cowshed logs --lines 5 >/dev/null || fail "logs"
[ "$(result exec printenv TOKEN)" = hidden-token-value ] || fail "exec has no secrets"
[ "$(result exec cat /app/version.txt)" = seven ] || fail "exec is not the live version"
[ "$(result exec sh -c 'echo "$0 two words"')" = "sh two words" ] || fail "exec lost its words"
if cowshed exec sh -c 'exit 4' > "$WORK/out"; then fail "exec hid a failure"; fi
grep -q "exit code 4" "$WORK/out" || fail "no exit code"

echo "== prune by hand: what is live stays"
cowshed prune | tail -1
[ "$(serving)" = seven ] || fail "prune touched what is live"
leftover=$(inside docker image ls --format '{{.Tag}}' e2e-app | while read -r tag; do
	inside docker ps -a --filter label=service=e2e --format '{{.Label "version"}}' | grep -qx "$tag" || echo "$tag"
done)
[ -z "$leftover" ] || fail "images of no container: $leftover"

echo "== audit"
cowshed audit | tail -3 | cut -c1-100

echo "== stop, and a version back on the air"
cowshed stop | cut -c1-80
# Traefik takes a removed route up to some seconds later (docs/spikes.md).
for _ in $(seq 30); do
	code=$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: e2e.example' "http://127.0.0.1:$WEB_PORT/")
	[ "$code" = 404 ] && break
	sleep 0.2
done
[ "$code" = 404 ] || fail "still routed: $code"
[ -z "$(live_containers | tr -d ' ')" ] || fail "something still runs"
cowshed rollback "$target" >/dev/null || fail "could not come back"
[ "$(serving)" = seven ] || fail "not back"

echo "== volumes and server-sent events, across a deploy and a rollback"
cowshed exec sh -c 'echo kept > /data/mark' >/dev/null || fail "exec could not write the volume"
was=$(inside docker ps --filter label=service=e2e --format '{{.Label "version"}}')
commit streaming
python3 "$ROOT/tests/sse.py" "$WEB_PORT" > "$WORK/sse" &
sse=$!
sleep 7 # Past the app's silence, longer than the route's idle timeout
# Server-sent events through the same switch: streamed at once, kept through a
# silence, on the old version until the drain ends them.
cowshed deploy > "$WORK/out" || { cat "$WORK/out"; fail "the deploy failed"; }
wait "$sse"
cat "$WORK/sse"
grep -q "first_s: 0\\." "$WORK/sse" || fail "the first event was held back"
grep -q "silence_survived: True" "$WORK/sse" || fail "a silence cut the stream"
grep -qx "versions: seven" "$WORK/sse" || fail "the stream moved to another version"
grep -q "ended: True" "$WORK/sse" || fail "the stream outlived the old container"
[ "$(serving)" = streaming ] || fail "not serving the new version"
[ "$(result exec cat /data/mark)" = kept ] || fail "exec does not see the volume"
now=$(inside docker ps --filter label=service=e2e --format '{{.Names}}')
[ "$(inside docker exec "$now" cat /data/mark)" = kept ] || fail "the new version lost the volume"
cowshed rollback "$was" > "$WORK/out" || { cat "$WORK/out"; fail "the rollback failed"; }
now=$(inside docker ps --filter label=service=e2e --format '{{.Names}}')
[ "$(inside docker exec "$now" cat /data/mark)" = kept ] || fail "the rollback lost the volume"
[ "$(serving)" = seven ] || fail "not back on seven"

echo "== remove: only with --yes"
if cowshed remove > "$WORK/out"; then fail "removed without --yes"; fi
[ "$(serving)" = seven ] || fail "removed without --yes"
cowshed remove --yes | tail -1
[ -z "$(inside docker ps -aq --filter label=service=e2e)" ] || fail "containers left"
[ -z "$(inside docker image ls -q e2e-app)" ] || fail "images left"
inside docker inspect legacy >/dev/null || fail "legacy was removed"
inside test -f /root/.cowshed/audit-e2e.log || fail "the audit log went too"

echo "== env_file: for a deploy with no source first"
printf 'export E2E_FROM_ENV=hidden-from-file\necho hidden-noise\n' > "$WORK/env"
env_config="$APP/config/env.yml"
{ cat "$APP/config/deploy.yml"; echo "env_file: $WORK/nowhere"; } > "$env_config"
if cowshed check -c "$env_config" > "$WORK/out"; then fail "check passed with no env_file"; fi
if cowshed deploy --force -c "$env_config" > "$WORK/out"; then fail "deployed with no env_file"; fi
grep -q "env_file.*is not there" "$WORK/out" || fail "wrong reason: $(cat "$WORK/out")"
grep -q "^build:" "$WORK/out" && fail "it built before finding the env_file missing"
{ cat "$APP/config/deploy.yml"; echo "env_file: $WORK/env"; } > "$env_config"
(unset E2E_FROM_ENV; cowshed deploy --force -c "$env_config") > "$WORK/out" || { cat "$WORK/out"; fail "the deploy with env_file failed"; }
grep -q hidden "$WORK/out" && fail "a value of the env_file in the output"
[ "$(result exec printenv OTHER)" = hidden-from-file ] || fail "the env_file's value did not arrive"
E2E_FROM_ENV=hidden-wins cowshed deploy --force -c "$env_config" > "$WORK/out" || { cat "$WORK/out"; fail "the deploy with env_file failed"; }
[ "$(result exec printenv OTHER)" = hidden-wins ] || fail "the environment did not win over the env_file"
rm "$env_config"
cowshed remove --yes > /dev/null
[ "$(inside cat /srv/e2e-data/mark)" = kept ] || fail "the volume's data went too"

echo "== migrate: before the new version, and a failure leaves the old one"
cowshed deploy --force > "$WORK/out" || { cat "$WORK/out"; fail "the deploy before migrating failed"; }
old=$(inside docker ps --filter label=service=e2e --format '{{.Names}}')
inside rm -f /srv/e2e-data/migrated
migrate_config="$APP/config/migrate.yml"
with_migrate() {
	{ cat "$APP/config/deploy.yml"; printf 'migrate:\n  command: sh -c \x27echo "$STEP" >> /data/migrated; test -n "$TOKEN"; test "$STEP" = ok\x27\n  timeout: %s\n  env:\n    STEP: %s\n' "$2" "$1"; } > "$migrate_config"
}
with_migrate bad 30
if cowshed deploy --force -c "$migrate_config" > "$WORK/out"; then fail "deployed past a failed migration"; fi
grep -q "the old version keeps serving" "$WORK/out" || fail "wrong reason: $(cat "$WORK/out")"
[ "$(inside docker ps --filter label=service=e2e --format '{{.Names}}')" = "$old" ] || fail "a failed migration changed what runs"
inside grep -qx bad /srv/e2e-data/migrated || fail "the migration did not reach the volume"
[ -z "$(inside docker ps -aq --filter label=oneoff=e2e)" ] || fail "the migration's container stayed"

{ cat "$APP/config/deploy.yml"; printf 'migrate:\n  command: sleep 60\n  timeout: 2\n'; } > "$migrate_config"
if cowshed deploy --force -c "$migrate_config" > "$WORK/out"; then fail "deployed past a migration out of time"; fi
grep -q "perhaps half done" "$WORK/out" || fail "wrong reason: $(cat "$WORK/out")"
[ "$(inside docker ps --filter label=service=e2e --format '{{.Names}}')" = "$old" ] || fail "a late migration changed what runs"
[ -z "$(inside docker ps -aq --filter label=oneoff=e2e)" ] || fail "the late migration's container stayed"

with_migrate ok 30
cowshed deploy --force -c "$migrate_config" > "$WORK/out" || { cat "$WORK/out"; fail "the deploy with a migration failed"; }
inside grep -qx ok /srv/e2e-data/migrated || fail "the migration did not run"
[ "$(inside docker ps --filter label=service=e2e --format '{{.Names}}')" != "$old" ] || fail "the new version did not go live"
if result exec printenv STEP >/dev/null 2>&1; then fail "the migration's variable reached the app"; fi
grep -q hidden "$WORK/out" && fail "a secret in the output"
rm "$migrate_config"
cowshed remove --yes > /dev/null

echo "e2e passed"
