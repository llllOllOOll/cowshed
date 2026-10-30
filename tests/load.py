#!/usr/bin/env python3
"""Traffic through a deploy, until a file named by the 2nd argument appears: a new
connection per request, a kept one, and a WebSocket. Prints what each saw."""
import base64, http.client, os, socket, sys, threading, time

PORT, STOP_FILE, HOST = int(sys.argv[1]), sys.argv[2], "e2e.example"
stop = False
results = {"new": {}, "kept": {}}


def note(kind, key):
    results[kind][key] = results[kind].get(key, 0) + 1


def requests(kind):
    conn = None
    while not stop:
        try:
            if kind == "new" or conn is None:
                conn = http.client.HTTPConnection("127.0.0.1", PORT, timeout=5)
            conn.request("GET", "/", headers={"Host": HOST})
            r = conn.getresponse()
            body = r.read().decode()
            note(kind, f"{r.status} {body}" if r.status != 200 else body)
            if kind == "new":
                conn.close()
        except Exception as e:
            note(kind, "error " + type(e).__name__)
            conn = None
        time.sleep(0.005)


ws = {"seen": {}, "closed": False}


def websocket():
    s = socket.create_connection(("127.0.0.1", PORT), timeout=60)
    key = base64.b64encode(os.urandom(16)).decode()
    s.sendall((f"GET /ws HTTP/1.1\r\nHost: {HOST}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
               f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
    data = b""
    while b"\r\n\r\n" not in data:
        data += s.recv(1)
    try:
        while True:
            head = s.recv(2, socket.MSG_WAITALL)
            if len(head) < 2:
                break
            text = s.recv(head[1], socket.MSG_WAITALL).decode()
            ws["seen"][text] = ws["seen"].get(text, 0) + 1
    except OSError:
        pass
    ws["closed"] = True


threads = [threading.Thread(target=requests, args=(k,), daemon=True) for k in ("new", "kept")]
threads.append(threading.Thread(target=websocket, daemon=True))
for t in threads:
    t.start()
while not os.path.exists(STOP_FILE):
    time.sleep(0.05)
time.sleep(1)
stop = True
print("new connection each:", results["new"])
print("kept alive:", results["kept"])
print("websocket:", ws["seen"], "closed:", ws["closed"])
bad = [k for r in results.values() for k in r if " " in k]
print("BAD" if bad else "CLEAN")
