#!/usr/bin/env bash
# A project in a monorepo, using an engine in another repository: `cowshed deploy`
# from clean copies, through real SSH on a throwaway server (Docker in Docker).
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SSH_PORT=12223
WEB_PORT=18091
NAME=cowshed-e2e-mono
WORK=$(mktemp -d)
export XDG_CACHE_HOME="$WORK/cache"
cleanup() {
	docker rm -f "$NAME" >/dev/null 2>&1 || true
	docker images --format '{{.Repository}}:{{.Tag}}' mono-app | xargs -r docker rmi >/dev/null 2>&1 || true
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

repo() {
	git init -q -b main "$1"
	git -C "$1" config user.email e2e@example.com
	git -C "$1" config user.name e2e-tester
}
save() { git -C "$1" add -A; git -C "$1" commit -qm "$2"; }

# games/engine, and games/mono/{game,other}.
repo "$WORK/games/engine"
echo engine-1 > "$WORK/games/engine/engine.txt"
save "$WORK/games/engine" engine
repo "$WORK/games/mono"
GAME="$WORK/games/mono/game"
mkdir -p "$GAME/config" "$GAME/tools" "$WORK/games/mono/other"
cp "$ROOT/tests/app/app.py" "$GAME/"
echo other > "$WORK/games/mono/other/file.txt"
echo game-1 > "$GAME/version.txt"
printf 'out/\ncache-kept/\n' > "$GAME/.gitignore"
cat > "$GAME/tools/stage.sh" <<'STAGE'
#!/bin/sh
set -e
# What is ignored stays between deploys in the copy.
[ -e cache-kept ] && echo "cache kept" || { mkdir cache-kept; echo "cache made"; }
rm -rf out; mkdir out
cp app.py out/
printf '%s %s\n' "$(cat version.txt)" "$(cat ../../engine/engine.txt)" > out/version.txt
printf 'FROM python:3-alpine\nCOPY app.py version.txt /app/\nCMD ["python", "/app/app.py"]\n' > out/Dockerfile
STAGE
chmod +x "$GAME/tools/stage.sh"
cat > "$GAME/config/deploy.yml" <<YAML
service: mono
image: mono-app
servers:
  - 127.0.0.1
ssh:
  user: root
  port: $SSH_PORT
  keys:
    - $WORK/key
proxy:
  host: mono.example
  app_port: 8000
branch: main
sources:
  - .
  - ../../engine
builder:
  before: tools/stage.sh
  context: out
  dockerfile: out/Dockerfile
drain_timeout: 1
YAML
save "$WORK/games/mono" start

cowshed() { (cd "$GAME" && "$ROOT/zig-out/bin/cowshed" "$@"); }
serving() { curl -s -H 'Host: mono.example' "http://127.0.0.1:$WEB_PORT/"; }
fail() { echo "FAILED: $*"; exit 1; }
wait_serving() {
	for _ in $(seq 30); do [ "$(serving)" = "$1" ] && return 0; sleep 0.2; done
	fail "not serving '$1': '$(serving)'"
}

cowshed setup > /dev/null

echo "== from another branch, with others' uncommitted work: main is what goes"
git -C "$WORK/games/mono" checkout -q -b someone-elses
echo "not committed" > "$GAME/version.txt"
echo "untracked" > "$GAME/stray.txt"
echo branch-only > "$GAME/app.py.note"
cowshed deploy > "$WORK/out" || { tail -5 "$WORK/out"; fail "deploy"; }
grep -E '^(source|notice|copies|deployed)' "$WORK/out" | cut -c1-100
wait_serving "game-1 engine-1"
grep -q "cache made" "$WORK/out" || fail "stage did not run in the copy"
[ ! -e "$GAME/cache-kept" ] || fail "built in the working folder"
[ "$(git -C "$WORK/games/mono" branch --show-current)" = someone-elses ] || fail "the branch moved"
[ "$(cat "$GAME/version.txt")" = "not committed" ] || fail "the working folder changed"

echo "== nothing changed: nothing happens"
before=$(cowshed versions)
cowshed deploy > "$WORK/out"
grep -q "nothing changed" "$WORK/out" || fail "it deployed again"
[ "$before" = "$(cowshed versions)" ] || fail "containers changed"

echo "== a commit elsewhere in the monorepo: still nothing"
git -C "$WORK/games/mono" stash -q -u
git -C "$WORK/games/mono" checkout -q main
echo more >> "$WORK/games/mono/other/file.txt"
save "$WORK/games/mono" "other project"
git -C "$WORK/games/mono" checkout -q someone-elses
git -C "$WORK/games/mono" stash pop -q
cowshed deploy > "$WORK/out"
grep -q "nothing changed" "$WORK/out" || { tail -3 "$WORK/out"; fail "another project's commit deployed this one"; }

echo "== the engine changed: it deploys, says from what, and keeps what git ignores"
echo engine-2 > "$WORK/games/engine/engine.txt"
save "$WORK/games/engine" engine2
cowshed deploy > "$WORK/out" || { tail -5 "$WORK/out"; fail "deploy"; }
wait_serving "game-1 engine-2"
grep -q "cache kept" "$WORK/out" || fail "the copy lost what git ignores"
cowshed versions | cut -c1-90
cowshed versions | grep -q '^live.*game@.*engine@' || fail "versions does not say from what"
docker exec "$NAME" cat /root/.cowshed/audit-mono.log | grep -q "from game@" || fail "the audit log does not say from what"

echo "== --force deploys the same again"
cowshed deploy --force > "$WORK/out" || { tail -5 "$WORK/out"; fail "force"; }
grep -q "^deployed" "$WORK/out" || fail "force did not deploy"
wait_serving "game-1 engine-2"

echo "== a commit in the project goes, on main only"
git -C "$WORK/games/mono" stash -q -u
git -C "$WORK/games/mono" checkout -q main
echo game-2 > "$GAME/version.txt"
save "$WORK/games/mono" game2
git -C "$WORK/games/mono" checkout -q someone-elses
echo game-wrong > "$GAME/version.txt"
save "$WORK/games/mono" "on the other branch"
cowshed deploy > "$WORK/out" || { tail -5 "$WORK/out"; fail "deploy"; }
wait_serving "game-2 engine-2"

echo "== --dirty: this folder as it is, as a test"
cowshed deploy --dirty > "$WORK/out" || { tail -5 "$WORK/out"; fail "dirty"; }
wait_serving "game-wrong engine-2"

echo "== a branch that does not exist stops it"
sed -i 's/^branch: main/branch: nothing/' "$GAME/config/deploy.yml"
if cowshed deploy > "$WORK/out"; then fail "deployed from no branch"; fi
grep -q "has no branch" "$WORK/out" || { cat "$WORK/out"; fail "wrong reason"; }

echo "e2e passed"
