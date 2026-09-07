#!/usr/bin/env python3
"""Real HTTP/WebSocket traffic through Caddy with a deterministic auth fixture."""
import base64
import hashlib
from http.client import HTTPConnection
import json
import os
import socket
import struct
import sys
import urllib.parse

HOST = "11111111-1111-1111-1111-111111111111.preview.example.test"
COOKIE = "__Host-abbey-quasar-preview=fixture-session"
SENSITIVE = {
    "Authorization": "Bearer operator-must-not-leak",
    "Cookie": COOKIE,
    "X-Abbey-Token": "operator-must-not-leak",
    "X-Abbey-Quasar-Token": "quasar-must-not-leak",
    "X-Abbey-Preview-Service-Token": "forged-service-token",
    "X-Abbey-Preview-Host": "forged-host",
    "X-Abbey-Preview-URI": "/forged-uri",
    "X-Quasar-Upstream": "attacker.invalid:9999",
}


# The module is imported as `HTTPConnection` on purpose: this helper is named
# `http`, so `import http.client` would leave `http` bound to this function and
# `http.client` would resolve against it. Stage 7 never ran until now, so that
# shadowing failed on its first execution with
# `AttributeError: 'function' object has no attribute 'client'`.
def http(port, host, path, headers=None):
    connection = HTTPConnection("127.0.0.1", port, timeout=10)
    try:
        connection.request("GET", path, headers={"Host": host, **(headers or {})})
        response = connection.getresponse()
        return response.status, dict((key.lower(), value) for key, value in response.getheaders()), response.read()
    finally:
        connection.close()


def assert_filtered(payload):
    assert payload["upstreamFixture"] is True, payload
    received = payload["headers"]
    assert received["host"] == HOST, received
    assert received["x-forwarded-host"] == HOST, received
    for header in SENSITIVE:
        assert header.lower() not in received, f"upstream received {header}"


def read_exact(stream, length):
    data = stream.read(length)
    if len(data) != length:
        raise AssertionError("WebSocket closed before completing a frame")
    return data


def read_text(stream):
    first, second = read_exact(stream, 2)
    assert first == 0x81 and second & 0x80 == 0, "expected unmasked complete server text frame"
    length = second & 127
    if length == 126:
        length = struct.unpack("!H", read_exact(stream, 2))[0]
    elif length == 127:
        length = struct.unpack("!Q", read_exact(stream, 8))[0]
    assert length <= 65536, "fixture frame exceeds bound"
    return read_exact(stream, length).decode()


def websocket(port, authorized):
    with socket.create_connection(("127.0.0.1", port), timeout=10) as connection:
        connection.settimeout(10)
        key = base64.b64encode(os.urandom(16)).decode()
        headers = {"Host": HOST, "Connection": "Upgrade", "Upgrade": "websocket",
                   "Sec-WebSocket-Version": "13", "Sec-WebSocket-Key": key}
        if authorized:
            headers.update(SENSITIVE)
        request = "GET /socket HTTP/1.1\r\n" + "".join(f"{name}: {value}\r\n" for name, value in headers.items()) + "\r\n"
        connection.sendall(request.encode())
        stream = connection.makefile("rb")
        status = stream.readline(4096).decode().strip()
        response_headers = {}
        for _ in range(100):
            line = stream.readline(8192)
            if line == b"\r\n":
                break
            assert line and b":" in line, "invalid WebSocket response headers"
            name, value = line.decode().split(":", 1)
            response_headers[name.lower()] = value.strip()
        else:
            raise AssertionError("too many WebSocket response headers")
        if not authorized:
            assert status.split()[1] == "401", status
            return
        assert status.split()[1] == "101", status
        expected_accept = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
        assert response_headers["sec-websocket-accept"] == expected_accept
        assert_filtered(json.loads(read_text(stream)))
        payload, mask = b"proxy-fixture-ping", os.urandom(4)
        connection.sendall(bytes([0x81, 0x80 | len(payload)]) + mask + bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload)))
        assert read_text(stream) == "echo:proxy-fixture-ping"


def run(port):
    assert http(port, "api.example.test", "/internal/quasar/preview/authorize", SENSITIVE)[0] == 404
    status, _, body = http(port, "api.example.test", "/api/status", SENSITIVE)
    assert status == 200
    operator = json.loads(body)
    assert operator["authorityFixture"] is True
    assert operator["headers"]["authorization"] == SENSITIVE["Authorization"]
    for header in ["X-Abbey-Preview-Service-Token", "X-Abbey-Preview-Host", "X-Abbey-Preview-URI", "X-Quasar-Upstream"]:
        assert header.lower() not in operator["headers"]
    assert http(port, HOST, "/", {"X-Quasar-Upstream": "preview-backend:8081"})[0] == 401
    assert http(port, HOST, "/", {"Cookie": "invalid-session"})[0] == 401
    ticket_path = "/_quasar/preview-session?" + urllib.parse.urlencode({"ticket": "fixture-ticket+with/slash"})
    status, headers, _ = http(port, HOST, ticket_path, SENSITIVE)
    assert status == 303, status
    assert headers["location"] == f"https://{HOST}/"
    assert "Secure" in headers["set-cookie"] and "HttpOnly" in headers["set-cookie"]
    assert "Domain=" not in headers["set-cookie"]
    assert http(port, HOST, ticket_path, SENSITIVE)[0] == 401, "ticket replay accepted"
    status, headers, body = http(port, HOST, "/echo", SENSITIVE)
    assert status == 200, status
    assert "set-cookie" not in headers, "upstream cookie escaped filtering"
    assert_filtered(json.loads(body))
    assert http(port, "22222222-2222-2222-2222-222222222222.preview.example.test", "/", SENSITIVE)[0] == 401
    websocket(port, authorized=False)
    websocket(port, authorized=True)
    print("CADDY_PROXY_FIXTURE_GREEN: real HTTP/WebSocket, ticket query/replay, host binding, upstream and credential filtering; fixture authorization, no TLS acceptance")


if __name__ == "__main__":
    run(int(sys.argv[1]))
