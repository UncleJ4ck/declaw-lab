#!/usr/bin/env python3
# Forwarding MITM for declaw-lab. Runs on the HOST with the stdlib only.
#
# The phone's apps are declaw-patched (ssl_verify_peer_cert forced to OK), so they accept
# ANY server certificate CHAIN. But Java clients (HttpsURLConnection/OkHttp) still run a
# HostnameVerifier that checks CN/SAN == host, so a fixed-CN cert would complete the TLS
# handshake and then the client sends nothing. So this mints a self-signed leaf with
# SAN = the SNI host, per host, on the fly. It terminates the app's TLS, reads the plaintext
# request, and hands it onward. Every request line is logged to capture/traffic.log.
#
# By default it forwards each flow INTO BURP (127.0.0.1:8080), so the decrypted request
# lands in Burp's HTTP history with no cert install on the phone. It talks to Burp with a
# normal CONNECT, so Burp needs only its default proxy listener (no invisible proxying).
# If Burp is not up, it falls back to a direct connection to the real server so capture
# still works. Set BURP= (empty) to always go direct, or BURP=host:port for a non-default
# listener.
#
# Env knobs: MITM_PORT (default 8083), MITM_BIND (default 0.0.0.0; the phone script pins
# it to the docker gateway so it is not LAN-exposed), BURP (default 127.0.0.1:8080),
# MITM_MAX_CONN (default 256, caps concurrent handler threads).
import os
import ssl
import socket
import threading
import datetime
import subprocess


def parse_host(req):
    """Extract the Host header value from raw HTTP request bytes, or None. Pure."""
    for line in req.split(b"\r\n"):
        if line[:5].lower() == b"host:":
            return line[5:].strip().decode("ascii", "replace")
    return None


def first_line(req):
    """The request line (first CRLF-delimited line), decoded loosely. Pure."""
    return req.split(b"\r\n", 1)[0].decode("ascii", "replace")


def main():
    HERE = os.path.dirname(os.path.abspath(__file__))
    ROOT = os.path.dirname(HERE)
    CERTDIR = os.path.join(HERE, "certs")          # per-SNI leaf cache
    LOG = os.environ.get("TRAFFIC_LOG") or os.path.join(ROOT, "capture", "traffic.log")
    PORT = int(os.environ.get("MITM_PORT", "8083"))
    BIND = os.environ.get("MITM_BIND", "0.0.0.0").strip() or "0.0.0.0"
    BURP = os.environ.get("BURP", "127.0.0.1:8080").strip()
    MAX_CONN = int(os.environ.get("MITM_MAX_CONN", "256"))

    # The declaw-patched app accepts any cert CHAIN (native ssl_verify_peer_cert forced OK),
    # but Java HostnameVerifier (HttpsURLConnection/OkHttp) still checks CN/SAN == host. A
    # single static-CN cert therefore completes the handshake and then the client sends nothing
    # (empty request). So mint a self-signed leaf with SAN = the SNI host, per host, on demand.
    os.makedirs(CERTDIR, exist_ok=True)
    os.makedirs(os.path.dirname(LOG), exist_ok=True)
    _cctx = {}
    _clock = threading.Lock()

    def ctx_for(host):
        host = host or "default"
        with _clock:
            c = _cctx.get(host)
            if c:
                return c
            crt = os.path.join(CERTDIR, host + ".crt")
            key = os.path.join(CERTDIR, host + ".key")
            if not (os.path.exists(crt) and os.path.exists(key)):
                san = "DNS:" + (host if host != "default" else "localhost")
                subprocess.run(
                    ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                     "-keyout", key, "-out", crt, "-days", "3650",
                     "-subj", "/CN=" + host, "-addext", "subjectAltName=" + san],
                    check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                )
            c = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            c.load_cert_chain(crt, key)
            c.set_alpn_protocols(["http/1.1"])     # force HTTP/1.1 so requests are readable
            _cctx[host] = c
            return c

    def sni_cb(sslobj, server_name, _ctx):
        sslobj.context = ctx_for(server_name)      # swap in a cert whose SAN matches the SNI

    sctx = ctx_for("default")
    sctx.sni_callback = sni_cb
    uctx = ssl.create_default_context()            # validates the REAL upstream (direct path)
    bctx = ssl.create_default_context()            # Burp presents its own cert, so don't verify
    bctx.check_hostname = False
    bctx.verify_mode = ssl.CERT_NONE
    log = open(LOG, "a", buffering=1)
    sem = threading.BoundedSemaphore(MAX_CONN)

    def ts():
        return datetime.datetime.now().strftime("%H:%M:%S")

    def pipe(src, dst):
        try:
            while True:
                d = src.recv(65536)
                if not d:
                    break
                dst.sendall(d)
        except Exception:
            pass
        finally:
            try:
                dst.shutdown(socket.SHUT_WR)
            except Exception:
                pass

    def open_upstream(host):
        # try Burp first (decrypted request shows in its history), else go direct
        if BURP:
            try:
                bhost, bport = BURP.rsplit(":", 1)
                raw = socket.create_connection((bhost, int(bport)), timeout=4)
                raw.sendall(f"CONNECT {host}:443 HTTP/1.1\r\nHost: {host}:443\r\n\r\n".encode())
                resp = raw.recv(4096)
                if b" 200 " in resp.split(b"\r\n", 1)[0]:
                    return bctx.wrap_socket(raw, server_hostname=host), "burp"
                raw.close()
            except OSError:
                pass  # Burp not listening -> fall through to direct
        raw = socket.create_connection((host, 443), timeout=8)
        return uctx.wrap_socket(raw, server_hostname=host), "direct"

    def handle(c, a):
        host = None
        cs = us = None
        try:
            cs = sctx.wrap_socket(c, server_side=True)   # patched app accepts our cert here
            cs.settimeout(8)
            sni = getattr(cs, "server_hostname", None)   # SNI, for cert match + host fallback
            req = b""
            while b"\r\n\r\n" not in req and len(req) < 65536:
                d = cs.recv(4096)
                if not d:
                    break
                req += d
            host = parse_host(req) or sni
            if not host:
                log.write(f"[{ts()}] NO_HOST {first_line(req)!r}\n")
                return
            us, via = open_upstream(host)
            log.write(f"[{ts()}] REQ https://{host}  {first_line(req)}  (via {via})\n")
            us.sendall(req)
            t = threading.Thread(target=pipe, args=(cs, us), daemon=True)
            t.start()
            pipe(us, cs)
            t.join(timeout=10)
        except ssl.SSLError as e:
            log.write(f"[{ts()}] TLS_FAIL host={host} {str(e)[:90]}\n")
        except Exception as e:
            log.write(f"[{ts()}] ERR host={host} {type(e).__name__} {str(e)[:90]}\n")
        finally:
            for s in (us, cs, c):
                try:
                    s.close()
                except Exception:
                    pass
            sem.release()

    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((BIND, PORT))
    srv.listen(200)
    dest = f"Burp {BURP}" if BURP else "direct + log"
    log.write(f"[{ts()}] MITM LISTENING {BIND}:{PORT} forwarding -> {dest}\n")
    print(f"declaw-mitm on {BIND}:{PORT} -> {dest}; log {LOG}")
    while True:
        c, a = srv.accept()
        sem.acquire()
        threading.Thread(target=handle, args=(c, a), daemon=True).start()


if __name__ == "__main__":
    main()
