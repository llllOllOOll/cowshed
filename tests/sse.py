"""Follows the test app's server-sent events through Traefik until the connection
ends, and says how the stream behaved."""
import http.client, sys, time

conn = http.client.HTTPConnection("127.0.0.1", int(sys.argv[1]), timeout=90)
start = time.monotonic()
conn.request("GET", "/events", headers={"Host": "e2e.example"})
response = conn.getresponse()
times, versions = [], set()
ended = False
try:
    while True:
        line = response.fp.readline()
        if not line:
            ended = True
            break
        if line.startswith(b"data: "):
            times.append(time.monotonic() - start)
            versions.add(line[6:].strip().decode())
except OSError:
    ended = True
gaps = [b - a for a, b in zip(times, times[1:])]
print(f"status: {response.status}")
print(f"events: {len(times)}")
print(f"first_s: {times[0]:.3f}" if times else "first_s: none")
print(f"silence_survived: {bool(gaps) and max(gaps) > 4 and len(times) > 2}")
print(f"versions: {','.join(sorted(versions))}")
print(f"ended: {ended}")
