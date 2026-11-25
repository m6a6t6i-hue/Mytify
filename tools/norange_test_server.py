"""HTTPS file server that ignores Range headers (like some simple servers).

usage: norange_test_server.py ROOT PORT CERT KEY
"""
import functools
import http.server
import ssl
import sys

root, port, cert, key = sys.argv[1:5]
handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=root)
httpd = http.server.ThreadingHTTPServer(("127.0.0.1", int(port)), handler)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(cert, key)
httpd.socket = context.wrap_socket(httpd.socket, server_side=True)
httpd.serve_forever()
