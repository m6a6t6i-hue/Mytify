"""HTTPS WebDAV server for the network source tests (wsgidav + cheroot).

usage: dav_test_server.py ROOT PORT CERT KEY USER PASSWORD
"""
import sys

from cheroot import wsgi
from cheroot.ssl.builtin import BuiltinSSLAdapter
from wsgidav.wsgidav_app import WsgiDAVApp

root, port, cert, key, user, password = sys.argv[1:7]
app = WsgiDAVApp({
    "host": "127.0.0.1",
    "port": int(port),
    "provider_mapping": {"/dav": root},
    "simple_dc": {"user_mapping": {"*": {user: {"password": password}}}},
    "http_authenticator": {"accept_basic": True, "accept_digest": False, "default_to_digest": False},
    "dir_browser": {"enable": False},
    "verbose": 1,
    "logging": {"enable_loggers": []},
})
server = wsgi.Server(("127.0.0.1", int(port)), app)
server.ssl_adapter = BuiltinSSLAdapter(cert, key)
server.start()
