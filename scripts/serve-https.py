#!/usr/bin/env python3
"""Serve web/ for this machine and for phones and tablets on the LAN.

WebKit — Safari, and every browser on iOS — runs a page that is not a secure context without
its optimising JIT: measured on the same machine, a plain integer loop takes nine times as long
at http://<lan-ip> as at http://localhost, and the game drops from over a thousand frames a
second to about sixty. http://localhost is a secure context, a LAN address is not; HTTPS makes
it one (and brings back the AudioWorklet too).

So there are two listeners. HTTPS on every interface (default 8443). And, with --http PORT,
plain HTTP that serves the page to this machine (localhost, 127.0.0.1) and redirects anyone
else to the HTTPS address of the same host — a phone keeps typing the old address and lands on
the fast one.

The certificate is self-signed, made once per LAN address with openssl and kept in
out/_web/tls/ (gitignored, like everything under out/). A phone shows a warning the first time;
accept it, or install the certificate and trust it (docs/WEB.md).

    python3 scripts/serve-https.py [https-port] [--http PORT]     # defaults: 8443, no HTTP
"""
import functools, http.server, os, socket, ssl, subprocess, sys, threading

root = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
web = os.path.join(root, 'web')
args = sys.argv[1:]
http_port = None
if '--http' in args:
    at = args.index('--http')
    http_port = int(args[at + 1])
    del args[at:at + 2]
https_port = int(args[0]) if args else 8443


def lan_address():
    # The address the machine would reach the outside world from; nothing is sent.
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        try:
            s.connect(('10.255.255.255', 1))
            return s.getsockname()[0]
        except OSError:
            return '127.0.0.1'


ip = lan_address()
tls = os.path.join(root, 'out', '_web', 'tls')
os.makedirs(tls, exist_ok=True)
cert, key = os.path.join(tls, f'{ip}.pem'), os.path.join(tls, f'{ip}.key')
if not (os.path.exists(cert) and os.path.exists(key)):
    subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '825',
                    '-keyout', key, '-out', cert, '-subj', f'/CN=recompsx {ip}',
                    '-addext', f'subjectAltName=IP:{ip},IP:127.0.0.1,DNS:localhost'],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

LOCAL = ('localhost', '127.0.0.1', '[::1]')


class LocalOrRedirect(http.server.SimpleHTTPRequestHandler):
    """HTTP: this machine gets the files, everyone else the HTTPS address of the same host."""

    def __init__(self, *a, **k):
        super().__init__(*a, directory=web, **k)

    def redirect_target(self):
        host = self.headers.get('Host') or ip
        name = host.split(']')[0] + ']' if host.startswith('[') else host.split(':')[0]
        return None if name in LOCAL else f'https://{name}:{https_port}{self.path}'

    def do_GET(self):
        target = self.redirect_target()
        if target is None:
            return super().do_GET()
        self.send_response(302)
        self.send_header('Location', target)
        self.send_header('Content-Length', '0')
        self.end_headers()

    do_HEAD = do_GET


secure = http.server.ThreadingHTTPServer(('0.0.0.0', https_port),
                                          functools.partial(http.server.SimpleHTTPRequestHandler, directory=web))
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(cert, key)
secure.socket = context.wrap_socket(secure.socket, server_side=True)
print(f'serving web/ at https://{ip}:{https_port}/ (certificate {os.path.relpath(cert, root)})', flush=True)
if http_port is not None:
    plain = http.server.ThreadingHTTPServer(('0.0.0.0', http_port), LocalOrRedirect)
    threading.Thread(target=plain.serve_forever, daemon=True).start()
    print(f'serving web/ at http://localhost:{http_port}/; other hosts are redirected to https', flush=True)
secure.serve_forever()
