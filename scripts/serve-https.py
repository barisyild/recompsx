#!/usr/bin/env python3
"""Serve web/ over HTTPS on every interface, for phones and tablets on the LAN.

WebKit — Safari, and every browser on iOS — runs a page that is not a secure context without
its optimising JIT: measured on the same machine, a plain integer loop takes nine times as long
at http://<lan-ip> as at http://localhost, and the game drops from over a thousand frames a
second to about sixty. http://localhost is a secure context, a LAN address is not; HTTPS makes
it one (and brings back the AudioWorklet too).

The certificate is self-signed, made once per LAN address with openssl and kept in
out/_web/tls/ (gitignored, like everything under out/). A phone shows a warning the first time;
accept it, or install the certificate and trust it (docs/WEB.md).

    python3 scripts/serve-https.py [port]          # default 8443
"""
import functools, http.server, os, socket, ssl, subprocess, sys

root = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
port = int(sys.argv[1]) if len(sys.argv) > 1 else 8443


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

handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=os.path.join(root, 'web'))
server = http.server.ThreadingHTTPServer(('0.0.0.0', port), handler)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(cert, key)
server.socket = context.wrap_socket(server.socket, server_side=True)
print(f'serving web/ at https://{ip}:{port}/ (certificate {os.path.relpath(cert, root)})', flush=True)
server.serve_forever()
