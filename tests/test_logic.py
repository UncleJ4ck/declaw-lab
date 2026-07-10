#!/usr/bin/env python3
# Unit tests for the MITM's pure request-parsing logic. Hard assertions on exact values,
# plus a parser fuzz (random bytes must never raise). No network, no sockets.
import sys
import os
import random

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "mitm"))
from mitm_fwd import parse_host, first_line  # noqa: E402

CASES = [
    (b"GET / HTTP/1.1\r\nHost: example.com\r\n\r\n", "example.com"),
    (b"GET /x HTTP/1.1\r\nhost: lower.example\r\n\r\n", "lower.example"),      # case-insensitive
    (b"GET / HTTP/1.1\r\nHost:   spaced.example  \r\n\r\n", "spaced.example"),  # trimmed
    (b"GET / HTTP/1.1\r\nHost: with.port:8443\r\n\r\n", "with.port:8443"),      # host:port kept
    (b"POST / HTTP/1.1\r\nX-A: 1\r\nHost: after.example\r\n\r\n", "after.example"),
    (b"GET / HTTP/1.1\r\n\r\n", None),                                          # no host header
    (b"", None),                                                               # empty
    (b"garbage with host: not-a-header inline", None),                          # 'host:' not at line start
    (b"Host: first.example\r\nHost: second.example\r\n\r\n", "first.example"),  # first wins
]

fails = 0
for req, want in CASES:
    got = parse_host(req)
    ok = got == want
    print(f"  {'PASS' if ok else 'FAIL'} parse_host -> {got!r} (want {want!r})")
    fails += (not ok)

for req, want in [(b"GET /a HTTP/1.1\r\nHost: x\r\n\r\n", "GET /a HTTP/1.1"), (b"", "")]:
    got = first_line(req)
    ok = got == want
    print(f"  {'PASS' if ok else 'FAIL'} first_line -> {got!r} (want {want!r})")
    fails += (not ok)

random.seed(1)
raised = None
for _ in range(5000):
    b = bytes(random.randint(0, 255) for _ in range(random.randint(0, 400)))
    try:
        parse_host(b)
        first_line(b)
    except Exception as e:
        raised = (b, e)
        break
if raised:
    print(f"  FAIL parser fuzz raised on {raised[0]!r}: {raised[1]}")
    fails += 1
else:
    print("  PASS parser fuzz: 5000 random inputs, no exception")

print(f"test_logic: {'FAIL' if fails else 'PASS'} ({fails} failures)")
sys.exit(1 if fails else 0)
