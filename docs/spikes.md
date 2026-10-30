# Risk tests (2026-10-30)

Run on this machine with a throwaway `traefik:3.6.6`, the version on the VPS, with
the VPS's provider flags, without TLS. Docker 29.9 here, 29.1 on the VPS. The
scripts are `tests/spikes/run.py` and `run2.py`; test 6 and the permission checks
only read the VPS.

**Not tested:** TLS and certificate issuing, real internet latency, and any of this
on the VPS itself. Traffic was a light loop of one client per mode. The image load
ran on this machine, with the base image's layers already present.

## Results

| # | Question | Result |
|---|---|---|
| 1 | Does a WebSocket survive a switch? | **Yes.** It stayed on the old container for the 10 s measured, while new requests got the new one. `docker stop` on the old closed it |
| 2 | Is a rename into a bind-mounted folder seen? | **Yes,** with no `watch` flag, as on the VPS |
| 3 | Errors during a switch? | **None** in 10 switches: 878 requests on new connections, 883 kept alive |
| 3 | Time to live | 0.16 to 2.19 s. The API showed the change at the same moment or before |
| 4 | A broken file | Live routes keep serving; **every later change is blocked, silently for the API**, which keeps showing the old state; Traefik logs an ERR. Removing the file applies the change |
| 4 | A half-written `.yml` | Blocks the same way |
| 4 | The same router name in an earlier file | **The earlier file wins** over ours |
| 5 | Counting connections | Works from `/proc/<pid>/net/tcp`, as a non-root user, here and on the VPS, with no tools in the image |
| 5 | Idle connections | **Traefik's pool held the old container for about 95 s** after the switch, so a count of zero says little by default |
| 5 | With `idleConnTimeout: 3s` on the route | The pool's connection left within 2 s; only the WebSocket remained |
| 6 | The VPS's Traefik | See below |
| 7 | Sending an image | See below |
| 8 | From labels to a file | With `priority: 1000` on the file router: **no errors,** the file route took over and the old could stop. **Without a priority the labelled router kept winning** (5 of 5) |
| - | Rollback | A stopped container started again and live in 2.15 s |

## The VPS (read-only)

`traefik:latest`, running 3.6.6, on `network_public`, entrypoint `websecure`, resolver
`letsencrypt`, file provider on `/etc/traefik`, from `/storage/traefik-app/config`
on the host (empty). API on 8080, not published.

- **The folder is `root:root 755`, and `seven` has no sudo: Cowshed cannot write
  there from the host.** Writing through the container works with no permission or
  restart: `docker exec -i <traefik> sh -c 'cat > .tmp && mv .tmp app.yml'`. So do
  the health probe and the API, with `docker exec <traefik> wget`. All three tested.
- **The `latest` tag floats:** a recreated container may bring another version. Not
  Cowshed's to change; `setup` should report it.
- **`rsync` is not installed there,** and without sudo it cannot be. `zstd` is.
- It has a 157 GB free disk.

## Sending an image

135 MB image plus a 20 MB layer standing for a code change. Docker's `save` already
compresses here (53.9 MB), so `zstd` gains nothing.

| Way | Sent for v2 | Needs on the server |
|---|---|---|
| `docker save`, whole | 53.8 MB | Docker |
| `rsync` of the tar | 20.0 MB | **rsync, which the VPS lacks** |
| A registry there | 19.6 MB | A registry always holding its layers |
| **Only the missing blobs** | **20.0 MB** | **Only Docker, `tar` and a folder** |

Missing blobs: `docker save` gives an OCI layout. Send only the `blobs/sha256/*` the
server's folder lacks, tar the image back there and `docker load` it. Rebuilt from a
cache folder and loaded: the image came back whole, 6 layers.

## What this changes in the design

1. **The switch stands:** files, renames, no gap in traffic.
2. **Writing, the health probe and the API go through Traefik's container,** and
   only with a helper container if its image has no shell.
3. **Every switch checks all the folder's files,** ours or not, and reports the file
   that blocks; a change not showing within a limit fails, with Traefik's error.
4. **File routers carry a high priority,** for moving from labels.
5. **Router names are checked across the folder,** since an earlier file wins.
6. **Drain:** each route sets a short `idleConnTimeout`, and the connections left are
   then real. Wait for zero or `drain_timeout`; the WebSockets are cut there.
7. **One way to send an image:** build here and send only missing blobs. No rsync,
   no registry and no builds on the server, so `builder.mode` goes away.
