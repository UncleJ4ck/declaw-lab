#!/usr/bin/env python3
# Network fuzz of the live MITM: raw garbage (breaks TLS) + valid TLS then garbage HTTP.
# Assert the process never crashes and still accepts a connection afterward.
import os
import ssl
import socket
import subprocess
import sys
import time
import signal
import random

DIR = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(DIR)
MITM = os.path.join(ROOT, "mitm", "mitm_fwd.py")
MPORT = 18087

env = dict(os.environ, MITM_PORT=str(MPORT), MITM_BIND="127.0.0.1", BURP="127.0.0.1:1")
proc = subprocess.Popen(["python3", MITM], env=env, cwd=ROOT,
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
time.sleep(2)
random.seed(2)
sent = 0

# phase A: raw garbage, no TLS -> exercises the handshake error path
for _ in range(300):
    try:
        s = socket.create_connection(("127.0.0.1", MPORT), timeout=3)
        s.sendall(bytes(random.randint(0, 255) for _ in range(random.randint(0, 600))))
        s.settimeout(1)
        try:
            s.recv(64)
        except Exception:
            pass
        s.close()
        sent += 1
    except Exception:
        pass

# phase B: real TLS handshake, then garbage HTTP -> exercises the request-read + parser path
cctx = ssl._create_unverified_context()
for _ in range(300):
    try:
        raw = socket.create_connection(("127.0.0.1", MPORT), timeout=3)
        s = cctx.wrap_socket(raw, server_hostname="fuzz")
        s.sendall(bytes(random.randint(0, 255) for _ in range(random.randint(0, 600))) + b"\r\n\r\n")
        s.settimeout(1)
        try:
            s.recv(64)
        except Exception:
            pass
        s.close()
        sent += 1
    except Exception:
        pass

alive = proc.poll() is None

# still accepting? host is a reserved-invalid TLD so upstream fails fast; MITM must not crash
final = False
try:
    raw = socket.create_connection(("127.0.0.1", MPORT), timeout=3)
    s = cctx.wrap_socket(raw, server_hostname="x")
    s.sendall(b"GET / HTTP/1.1\r\nHost: nonexistent.invalid\r\nConnection: close\r\n\r\n")
    s.settimeout(2)
    try:
        s.recv(64)
    except Exception:
        pass
    s.close()
    final = True
except Exception:
    pass

proc.send_signal(signal.SIGTERM)
try:
    proc.wait(timeout=5)
except Exception:
    proc.kill()

print(f"  fuzz payloads sent: {sent}/600")
print(f"  MITM alive after fuzz: {alive}; still accepting after: {final}")
fail = 0 if (alive and final) else 1
if not alive:
    print("  FAIL: MITM crashed during fuzz")
if not final:
    print("  FAIL: MITM not accepting after fuzz")
print(f"fuzz_mitm: {'FAIL' if fail else 'PASS'}")
sys.exit(fail)
