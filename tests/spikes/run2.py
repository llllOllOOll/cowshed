#!/usr/bin/env python3
"""Second round of the risk tests: what the first opened, and the image's sending."""
import os, pathlib, re, shutil, subprocess, tempfile, time, sys
sys.argv = ["x"]
src = pathlib.Path(__file__).with_name("run.py").read_text().rsplit("main()", 1)[0]
exec(src)


def route_idle(version, idle):
    return f"""http:
  routers:
    cowshed-app:
      rule: Host(`{HOST}`)
      entryPoints: [web]
      service: cowshed-app
  services:
    cowshed-app:
      loadBalancer:
        serversTransport: cowshed-app
        servers:
          - url: http://spike-app-{version}:8000
  serversTransports:
    cowshed-app:
      forwardingTimeouts:
        idleConnTimeout: {idle}
"""


def exec_put(name, text):
    """Through Traefik's own container: nothing on the host needs to be writable."""
    p = subprocess.run(["docker", "exec", "-i", "spike-traefik", "sh", "-c",
                        f"cat > /etc/traefik/.{name}.tmp && mv /etc/traefik/.{name}.tmp /etc/traefik/{name}"],
                       input=text, text=True, capture_output=True)
    assert p.returncode == 0, p.stderr


def host_conns(container):
    pid = sh("docker", "inspect", "-f", "{{.State.Pid}}", container)
    n = 0
    for f in ("tcp", "tcp6"):
        for line in pathlib.Path(f"/proc/{pid}/net/{f}").read_text().splitlines()[1:]:
            x = line.split()
            if x[3] == "01" and x[1].endswith(":1F40"):
                n += 1
    return n


def images():
    print("\n== 7. Sending an image", flush=True)
    base = "orbitx-test:latest"
    d = pathlib.Path(tempfile.mkdtemp(prefix="cowshed-img-"))
    try:
        (d / "app.bin").write_bytes(os.urandom(20_000_000))
        (d / "Dockerfile").write_text(f"FROM {base}\nCOPY app.bin /app.bin\n")
        sh("docker", "build", "-q", "-t", "spike-img:1", str(d))
        (d / "app.bin").write_bytes(os.urandom(20_000_000))
        sh("docker", "build", "-q", "-t", "spike-img:2", str(d))
        print("(a 135 MB image plus a 20 MB incompressible layer: a code change, one layer)")
        for tag in "12":
            start = time.monotonic()
            subprocess.run(f"docker save spike-img:{tag} > {d}/{tag}.tar", shell=True, check=True)
            subprocess.run(f"zstd -q -f -3 {d}/{tag}.tar -o {d}/{tag}.tar.zst", shell=True, check=True)
            print(f"save|zstd v{tag}: tar {os.path.getsize(d / f'{tag}.tar') / 1e6:.1f} MB, sent "
                  f"{os.path.getsize(d / f'{tag}.tar.zst') / 1e6:.1f} MB, {time.monotonic() - start:.1f} s")
        (d / "server").mkdir()
        shutil.copy(d / "1.tar", d / "server" / "image.tar")
        shutil.copy(d / "2.tar", d / "image.tar")
        out = sh("rsync", "-a", "--ignore-times", "--no-whole-file", "--compress", "--stats", str(d / "image.tar"), str(d / "server/image.tar"))
        print("rsync of the tar, v1 there, v2 sent:", " | ".join(l for l in out.splitlines() if re.match("Literal|Matched|Total bytes sent", l)))
        sh("docker", "run", "-d", "--name", "spike-registry", "-p", "127.0.0.1:18082:5000", "registry:2")
        time.sleep(2)
        def du():
            return int(sh("docker", "exec", "spike-registry", "du", "-sk", "/var/lib/registry").split()[0]) / 1000
        for tag in "12":
            sh("docker", "tag", f"spike-img:{tag}", f"127.0.0.1:18082/img:{tag}")
            before = du(); start = time.monotonic()
            sh("docker", "push", "-q", f"127.0.0.1:18082/img:{tag}")
            print(f"registry on the server, v{tag}: {du() - before:.1f} MB new, {time.monotonic() - start:.1f} s")
    finally:
        for t in ("spike-img:1", "spike-img:2", "127.0.0.1:18082/img:1", "127.0.0.1:18082/img:2"):
            sh("docker", "rmi", t, check=False)
        shutil.rmtree(d, ignore_errors=True)


def main():
    cleanup()
    sh("docker", "network", "create", NET)
    root = pathlib.Path(tempfile.mkdtemp(prefix="cowshed-spike-"))
    routes = root / "routes"; routes.mkdir()
    try:
        sh("docker", "run", "-d", "--name", "spike-traefik", "--network", NET,
           "-p", f"127.0.0.1:{WEB}:80", "-v", f"{routes}:/etc/traefik",
           "-v", "/var/run/docker.sock:/var/run/docker.sock:ro", TRAEFIK,
           "--api.insecure=true", "--log.level=INFO", "--entrypoints.web.address=:80",
           "--providers.docker=true", "--providers.docker.exposedbydefault=false",
           "--providers.file.directory=/etc/traefik")
        time.sleep(3)

        print("== A. Through Traefik's container: write, health and API", flush=True)
        app("v1"); app("v2")
        exec_put("app.yml", route_idle("v1", "3s")); print("live after", wait_version("v1"))
        print("health of a container from inside the network:",
              sh("docker", "exec", "spike-traefik", "wget", "-qO-", "http://spike-app-v2:8000/up"))
        out = sh("docker", "exec", "spike-traefik", "wget", "-qO-", "http://localhost:8080/api/http/services/cowshed-app@file")
        print("the API from inside shows v1:", "spike-app-v1" in out)

        print("\n== B. A short idle time on the route, and draining", flush=True)
        for _ in range(50):
            get()
        print("connections on v1 after 50 requests:", conns("spike-app-v1"), "from the host:", host_conns("spike-app-v1"))
        ws = Ws(); time.sleep(0.5)
        exec_put("app.yml", route_idle("v2", "3s")); print("switch live after", wait_version("v2"))
        start = time.monotonic(); seen = []
        while time.monotonic() - start < 12:
            seen.append((round(time.monotonic() - start), host_conns("spike-app-v1"))); time.sleep(2)
        print("on v1 with a websocket open (s, n):", seen, "websocket closed:", ws.closed_at is not None)
        sh("docker", "stop", "spike-app-v1"); time.sleep(1)
        print("v1 stopped; websocket closed:", ws.closed_at is not None)

        print("\n== C. Rollback: the stopped container started again", flush=True)
        sh("docker", "start", "spike-app-v1"); 
        start = time.monotonic()
        exec_put("app.yml", route_idle("v1", "3s")); print("rollback live after", wait_version("v1"), "total", round(time.monotonic() - start, 2))

        print("\n== D. How a broken file shows", flush=True)
        (routes / "broken.yml").write_text("http:\n  routers: [nonsense\n"); time.sleep(3)
        logs = subprocess.run(["docker", "logs", "--tail", "6", "spike-traefik"], capture_output=True, text=True)
        for l in (logs.stdout + logs.stderr).splitlines():
            print(l[:210])
        (routes / "broken.yml").unlink()
        images()
    finally:
        cleanup()
        shutil.rmtree(root, ignore_errors=True)


main()
