#!/usr/bin/env python3
"""The risk tests for Cowshed's design, on a throwaway Traefik on this machine.
Uses only what it names spike-*, and removes it at the end. Results: docs/spikes.md."""
import base64, http.client, os, pathlib, shutil, socket, subprocess, sys, tempfile, threading, time, urllib.request, json

HERE = pathlib.Path(__file__).parent.resolve()
TRAEFIK = "traefik:3.6.6"  # the version on the VPS
NET = "spike-net"
WEB, API = 18080, 18081
HOST = "app.test"


def sh(*args, check=True):
    r = subprocess.run(args, capture_output=True, text=True)
    if check and r.returncode:
        sys.exit(f"failed: {' '.join(args)}\n{r.stderr}")
    return r.stdout.strip()


def cleanup():
    ids = sh("docker", "ps", "-aq", "--filter", "name=^spike-").split()
    if ids:
        sh("docker", "rm", "-f", *ids)
    sh("docker", "network", "rm", NET, check=False)


def app(version, labels=()):
    args = ["docker", "run", "-d", "--name", f"spike-app-{version}", "--network", NET, "-e", f"VERSION={version}",
            "-v", f"{HERE}/backend.py:/backend.py:ro", "--label", "spike=1"]
    for label in labels:
        args += ["--label", label]
    sh(*args, "python:3-alpine", "python", "/backend.py")
    time.sleep(1)


def route(version, priority=None):
    p = f"\n      priority: {priority}" if priority else ""
    return f"""http:
  routers:
    cowshed-app:
      rule: Host(`{HOST}`)
      entryPoints: [web]
      service: cowshed-app{p}
  services:
    cowshed-app:
      loadBalancer:
        servers:
          - url: http://spike-app-{version}:8000
"""


def put(folder, name, text):
    """Rename into place, as Cowshed would. The temporary name has no .yml."""
    tmp = folder / f".{name}.tmp"
    tmp.write_text(text)
    os.rename(tmp, folder / name)


def get(host=HOST, timeout=3):
    c = http.client.HTTPConnection("127.0.0.1", WEB, timeout=timeout)
    c.request("GET", "/", headers={"Host": host})
    r = c.getresponse()
    body = r.read().decode()
    c.close()
    return r.status, body


def wait_version(version, limit=15):
    start = time.monotonic()
    while time.monotonic() - start < limit:
        try:
            s, b = get()
            if s == 200 and b == version:
                return time.monotonic() - start
        except OSError:
            pass
        time.sleep(0.005)
    return None


def api(path):
    with urllib.request.urlopen(f"http://127.0.0.1:{API}{path}", timeout=3) as r:
        return json.load(r)


def api_server(version):
    try:
        s = api("/api/http/services/cowshed-app@file")
        return any(version in x["url"] for x in s["loadBalancer"]["servers"])
    except Exception:
        return False


class Ws:
    """A WebSocket client through Traefik, recording what it receives."""

    def __init__(self):
        self.seen, self.closed_at, self.last = {}, None, 0
        self.s = socket.create_connection(("127.0.0.1", WEB), timeout=30)
        key = base64.b64encode(os.urandom(16)).decode()
        self.s.sendall((f"GET /ws HTTP/1.1\r\nHost: {HOST}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                        f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
        head = b""
        while b"\r\n\r\n" not in head:
            head += self.s.recv(1)
        assert b" 101 " in head.split(b"\r\n")[0], head
        threading.Thread(target=self.read, daemon=True).start()

    def read(self):
        try:
            while True:
                h = self.exact(2)
                text = self.exact(h[1]).decode()
                v = text.split()[0]
                self.seen[v] = self.seen.get(v, 0) + 1
                self.last = time.monotonic()
        except (OSError, EOFError):
            self.closed_at = time.monotonic()

    def exact(self, n):
        out = b""
        while len(out) < n:
            d = self.s.recv(n - len(out))
            if not d:
                raise EOFError
            out += d
        return out


def conns(container):
    """Established connections to port 8000, seen from the container's network,
    with a helper container: the image itself needs no tools."""
    out = sh("docker", "run", "--rm", "--network", f"container:{container}", "python:3-alpine", "cat",
             "/proc/net/tcp", "/proc/net/tcp6")
    n = 0
    for line in out.splitlines():
        f = line.split()
        if len(f) > 3 and f[3] == "01" and f[1].endswith(":1F40"):
            n += 1
    return n


class Load:
    """Requests in a loop while something happens: each new connection, and one kept alive."""

    def __init__(self, keep_alive):
        self.keep_alive, self.stop, self.ok, self.bad, self.errors = keep_alive, False, {}, {}, []
        self.t = threading.Thread(target=self.run, daemon=True)
        self.t.start()

    def note(self, status, body):
        if status == 200:
            self.ok[body] = self.ok.get(body, 0) + 1
        else:
            self.bad[status] = self.bad.get(status, 0) + 1

    def run(self):
        c = None
        while not self.stop:
            try:
                if not self.keep_alive or c is None:
                    c = http.client.HTTPConnection("127.0.0.1", WEB, timeout=3)
                c.request("GET", "/", headers={"Host": HOST})
                r = c.getresponse()
                self.note(r.status, r.read().decode())
                if not self.keep_alive:
                    c.close()
            except Exception as e:
                self.errors.append(type(e).__name__)
                c = None
            time.sleep(0.002)

    def end(self):
        self.stop = True
        self.t.join()
        return f"ok={self.ok} bad={self.bad} errors={len(self.errors)}"


def spike1(routes):
    print("\n== 1. A WebSocket across a switch")
    app("v1"); put(routes, "app.yml", route("v1")); print("live after", wait_version("v1"))
    ws = Ws(); time.sleep(1)
    app("v2"); put(routes, "app.yml", route("v2")); t = wait_version("v2")
    print(f"switched in {t:.3f}s; a new request gets {get()[1]}")
    before = dict(ws.seen); time.sleep(10)
    print(f"websocket: before {before}, 10 s after the switch {ws.seen}, closed={ws.closed_at is not None}")
    print("connections on v1 with the websocket open:", conns("spike-app-v1"))
    start = time.monotonic(); sh("docker", "stop", "spike-app-v1")
    time.sleep(1)
    print(f"docker stop took {time.monotonic() - start - 1:.2f}s; websocket closed={ws.closed_at is not None}")
    sh("docker", "rm", "-f", "spike-app-v1")


def spike2(routes):
    print("\n== 2+3. Rename into a bind-mounted folder, under load, repeated")
    current = "v2"
    a, b = Load(False), Load(True)
    times, api_times = [], []
    app("v3")
    for i in range(10):
        current = "v3" if current == "v2" else "v2"
        start = time.monotonic()
        put(routes, "app.yml", route(current))
        at = None
        while time.monotonic() - start < 15:
            if at is None and api_server(f"spike-app-{current}"):
                at = time.monotonic() - start
            if at is not None:
                break
            time.sleep(0.005)
        t = wait_version(current)
        times.append(time.monotonic() - start); api_times.append(at)
        time.sleep(3)
    print("new connection each:", a.end())
    print("kept alive:", b.end())
    print("seconds to live:", " ".join(f"{x:.2f}" for x in times))
    print("seconds until the API shows it:", " ".join(f"{x:.2f}" for x in api_times))
    print("-- a burst: changes 0.2 s apart")
    start = time.monotonic()
    for i in range(6):
        current = "v3" if current == "v2" else "v2"
        put(routes, "app.yml", route(current)); time.sleep(0.2)
    print(f"last of the burst live {wait_version(current) + 1.2:.2f}s after the burst began")
    return current


def spike4(routes, current):
    print("\n== 4. A broken file in the folder")
    other = "v3" if current == "v2" else "v2"
    (routes / "broken.yml").write_text("http:\n  routers: [nonsense\n")
    time.sleep(4)
    print("live route still serves:", get())
    put(routes, "app.yml", route(other))
    time.sleep(6)
    print(f"6 s after a change to {other}: serving {get()[1]}, API shows it: {api_server('spike-app-' + other)}")
    (routes / "broken.yml").unlink()
    print("broken file removed; change live after", wait_version(other))
    print("-- a broken file seen through the API?")
    (routes / "broken.yml").write_text("http:\n  routers: [nonsense\n")
    time.sleep(4)
    print("routers in the API:", [r["name"] for r in api("/api/http/routers") if "cowshed" in r["name"]])
    (routes / "broken.yml").unlink()
    time.sleep(3)
    print("-- a temporary name ending in .yml, half written")
    (routes / "half.yml").write_text("http:\n  routers:\n    x: {rule: ")
    time.sleep(3)
    third = current if other != current else other
    put(routes, "app.yml", route(third)); time.sleep(4)
    print(f"blocked while half.yml exists: serving {get()[1]}, wanted {third}")
    (routes / "half.yml").unlink(); print("live after removal", wait_version(third))
    print("-- the same router name in an earlier file")
    (routes / "aaa.yml").write_text(route(other)); time.sleep(4)
    print(f"app.yml says {third}, aaa.yml says {other}: serving {get()[1]}")
    (routes / "aaa.yml").unlink(); print("live after removal", wait_version(third))
    return third


def spike5(routes, current):
    print("\n== 5. Counting connections from the container's side")
    other = "v3" if current == "v2" else "v2"
    for _ in range(50):
        get()
    print(f"on {current} after 50 requests:", conns(f"spike-app-{current}"))
    put(routes, "app.yml", route(other)); wait_version(other)
    start = time.monotonic(); seen = []
    while time.monotonic() - start < 110:
        n = conns(f"spike-app-{current}")
        seen.append((round(time.monotonic() - start), n))
        if n == 0:
            break
        time.sleep(5)
    print("idle connections on the old one after the switch (s, n):", seen)
    pid = sh("docker", "inspect", "-f", "{{.State.Pid}}", f"spike-app-{current}")
    try:
        lines = pathlib.Path(f"/proc/{pid}/net/tcp").read_text().splitlines()
        print(f"/proc/<pid>/net/tcp from the host, as this user: readable, {len(lines)} lines")
    except OSError as e:
        print("/proc/<pid>/net/tcp from the host, as this user:", e)
    return other


def spike8(routes):
    print("\n== 8. From labels to a file, on one Host")
    (routes / "app.yml").unlink(); time.sleep(3)
    app("old", labels=["traefik.enable=true", f"traefik.http.routers.game.rule=Host(`{HOST}`)",
                       "traefik.http.routers.game.entrypoints=web",
                       "traefik.http.services.game.loadbalancer.server.port=8000",
                       f"traefik.docker.network={NET}"])
    print("label route live after", wait_version("old"))
    a, b = Load(False), Load(True)
    ws = Ws(); time.sleep(1)
    app("new")
    put(routes, "app.yml", route("new", priority=1000))
    print("file route wins after", wait_version("new"))
    time.sleep(3)
    print("with both routers: served", get()[1])
    sh("docker", "stop", "spike-app-old"); time.sleep(2)
    print("new connection each:", a.end())
    print("kept alive:", b.end())
    print("websocket on the labelled one:", ws.seen, "closed:", ws.closed_at is not None)
    sh("docker", "rm", "-f", "spike-app-old")
    print("-- without a priority: same rule, both routers")
    app("old2", labels=["traefik.enable=true", f"traefik.http.routers.game.rule=Host(`{HOST}`)",
                        "traefik.http.routers.game.entrypoints=web",
                        "traefik.http.services.game.loadbalancer.server.port=8000",
                        f"traefik.docker.network={NET}"])
    put(routes, "app.yml", route("new")); time.sleep(5)
    print("served 5 times:", [get()[1] for _ in range(5)])


def main():
    cleanup()
    sh("docker", "pull", "-q", TRAEFIK); sh("docker", "pull", "-q", "python:3-alpine")
    sh("docker", "network", "create", NET)
    root = pathlib.Path(tempfile.mkdtemp(prefix="cowshed-spike-"))
    routes = root / "routes"; routes.mkdir()
    try:
        # The VPS's flags, less TLS and the redirect; no explicit watch, as there.
        sh("docker", "run", "-d", "--name", "spike-traefik", "--network", NET,
           "-p", f"127.0.0.1:{WEB}:80", "-p", f"127.0.0.1:{API}:8080",
           "-v", f"{routes}:/etc/traefik", "-v", "/var/run/docker.sock:/var/run/docker.sock:ro", TRAEFIK,
           "--api.insecure=true", "--log.level=INFO", "--entrypoints.web.address=:80",
           "--providers.docker=true", "--providers.docker.exposedbydefault=false",
           "--providers.file.directory=/etc/traefik")
        time.sleep(3)
        spike1(routes)
        current = spike2(routes)
        current = spike4(routes, current)
        current = spike5(routes, current)
        spike8(routes)
        print("\n== Traefik's log, errors")
        logs = subprocess.run(["docker", "logs", "spike-traefik"], capture_output=True, text=True)
        for line in (logs.stdout + logs.stderr).splitlines():
            if " ERR " in line:
                print(line[:220])
    finally:
        cleanup()
        shutil.rmtree(root, ignore_errors=True)


main()
