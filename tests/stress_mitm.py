#!/usr/bin/env python3
# Stress + resource-leak regression for the MITM. Fires N concurrent full requests
# through a local stub "Burp", then asserts: no crash, thread count stays under the
# MITM_MAX_CONN cap, file descriptors return to baseline (no leak), still serves after.
# Set MITM_SCRIPT=<path> to run against a different mitm build (used for red/green).
import os
import ssl
import socket
import subprocess
import threading
import sys
import time
import signal
import tempfile
import concurrent.futures as cf

DIR = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(DIR)
MITM = os.environ.get("MITM_SCRIPT", os.path.join(ROOT, "mitm", "mitm_fwd.py"))
MPORT, BPORT = 18085, 18086
N = int(os.environ.get("N", "400"))
CONC = int(os.environ.get("CONC", "80"))
CAP = 64

# --- stub "Burp": accept CONNECT, break TLS, answer 200 ok ---
cdir = tempfile.mkdtemp()
sc, sk = os.path.join(cdir, "s.pem"), os.path.join(cdir, "s.key")
subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", sk,
                "-out", sc, "-days", "1", "-subj", "/CN=stub"], check=True, capture_output=True)
sctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
sctx.load_cert_chain(sc, sk)


def stub_handle(c):
    try:
        b = b""
        while b"\r\n\r\n" not in b:
            d = c.recv(1024)
            if not d:
                return
            b += d
        c.sendall(b"HTTP/1.1 200 Connection established\r\n\r\n")
        s = sctx.wrap_socket(c, server_side=True)
        s.recv(4096)
        s.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
    except Exception:
        pass
    finally:
        try:
            c.close()
        except Exception:
            pass


def stub():
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", BPORT))
    srv.listen(200)
    while True:
        c, _ = srv.accept()
        threading.Thread(target=stub_handle, args=(c,), daemon=True).start()


threading.Thread(target=stub, daemon=True).start()

env = dict(os.environ, MITM_PORT=str(MPORT), MITM_BIND="127.0.0.1",
           BURP=f"127.0.0.1:{BPORT}", MITM_MAX_CONN=str(CAP))
proc = subprocess.Popen(["python3", MITM], env=env, cwd=ROOT,
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
time.sleep(2)
pid = proc.pid


def fds():
    try:
        return len(os.listdir(f"/proc/{pid}/fd"))
    except Exception:
        return -1


def nthreads():
    try:
        return len(os.listdir(f"/proc/{pid}/task"))
    except Exception:
        return -1


base_fd, base_th = fds(), nthreads()
cctx = ssl._create_unverified_context()
ok = [0]
err = [0]
lock = threading.Lock()


def client(i):
    try:
        raw = socket.create_connection(("127.0.0.1", MPORT), timeout=8)
        s = cctx.wrap_socket(raw, server_hostname="stress.test")
        s.sendall(b"GET /%d HTTP/1.1\r\nHost: stress.test\r\nConnection: close\r\n\r\n" % i)
        d = s.recv(200)
        with lock:
            if b"200 OK" in d:
                ok[0] += 1
            else:
                err[0] += 1
        s.close()
    except Exception:
        with lock:
            err[0] += 1


peak_fd, peak_th = base_fd, base_th
with cf.ThreadPoolExecutor(max_workers=CONC) as ex:
    futs = [ex.submit(client, i) for i in range(N)]
    while any(not f.done() for f in futs):
        peak_fd = max(peak_fd, fds())
        peak_th = max(peak_th, nthreads())
        time.sleep(0.03)
    for f in futs:
        f.result()

time.sleep(3)  # let handlers unwind
end_fd, end_th = fds(), nthreads()

# --- slowloris phase: open K > cap connections that TLS-handshake then STALL (no request
# terminator) and hold. This is the condition the concurrency cap actually defends: with a
# cap the handler-thread count stays bounded; without one it climbs to K. ---
K = CAP * 3
stop = threading.Event()
slow_peak_th = [nthreads()]


def slow(i):
    try:
        raw = socket.create_connection(("127.0.0.1", MPORT), timeout=5)
        try:
            s = cctx.wrap_socket(raw, server_hostname="slow")
            s.sendall(b"GET / HTTP/1.1\r\nHost: slow\r\n")   # partial: no blank line
        except Exception:
            pass
        stop.wait(5)
        try:
            raw.close()
        except Exception:
            pass
    except Exception:
        pass


slow_threads = [threading.Thread(target=slow, args=(i,), daemon=True) for i in range(K)]
for t in slow_threads:
    t.start()
t0 = time.time()
while time.time() - t0 < 3:
    slow_peak_th[0] = max(slow_peak_th[0], nthreads())
    time.sleep(0.03)
slow_peak = slow_peak_th[0]
stop.set()
time.sleep(1)
alive = proc.poll() is None

final_ok = False
try:
    raw = socket.create_connection(("127.0.0.1", MPORT), timeout=8)
    s = cctx.wrap_socket(raw, server_hostname="x")
    s.sendall(b"GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
    final_ok = b"200 OK" in s.recv(200)
    s.close()
except Exception:
    pass

proc.send_signal(signal.SIGTERM)
try:
    proc.wait(timeout=5)
except Exception:
    proc.kill()

print(f"  throughput: {N} reqs (conc {CONC}), ok={ok[0]} err={err[0]}")
print(f"  fds:     base={base_fd} peak={peak_fd} end={end_fd}")
print(f"  threads: base={base_th} peak={peak_th} end={end_th}")
print(f"  slowloris: {K} stalled conns -> peak threads={slow_peak} (cap {CAP})")
print(f"  alive after: {alive}; served after: {final_ok}")
fail = 0
if not alive:
    print("  FAIL: MITM died under load")
    fail = 1
if ok[0] < N * 0.9:
    print(f"  FAIL: too many errors ({err[0]}/{N})")
    fail = 1
if slow_peak > CAP + 16:
    print(f"  FAIL: concurrency cap breached under slowloris (peak {slow_peak} > {CAP}+16)")
    fail = 1
if end_fd > base_fd + 16:
    print(f"  FAIL: fd leak after throughput burst (end {end_fd} vs base {base_fd})")
    fail = 1
if not final_ok:
    print("  FAIL: stopped serving after burst")
    fail = 1
print(f"stress_mitm: {'FAIL' if fail else 'PASS'}")
sys.exit(fail)
