import copy
import importlib.util
import io
from pathlib import Path
import struct
import unittest


def load(name):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


config = load("caddy-http-config")
proxy = load("proxy-check")


class ProxyChecks(unittest.TestCase):
    def test_plaintext_preserves_all_production_routes(self):
        routes = [{"match": [{"host": [proxy.HOST]}], "handle": [{"handler": "reverse_proxy", "upstreams": [{"dial": "abbey:8080"}]}]}]
        original = {"apps": {"tls": {"automation": {}}, "http": {"servers": {"srv0": {"listen": [":443"], "routes": copy.deepcopy(routes), "tls_connection_policies": [{}]}}}}}
        result = config.plaintext(original)
        server = result["apps"]["http"]["servers"]["srv0"]
        self.assertEqual(server["routes"], routes)
        self.assertEqual(server["listen"], [":8080"])
        self.assertTrue(server["automatic_https"]["disable"])
        self.assertNotIn("tls", result["apps"])
        self.assertNotIn("tls_connection_policies", server)

    def test_rejects_unexpected_listener_shape(self):
        with self.assertRaises(ValueError):
            config.plaintext({"apps": {"http": {"servers": {"a": {}, "b": {}}}}})

    def test_all_credential_headers_are_rejected(self):
        headers = {"host": proxy.HOST, "x-forwarded-host": proxy.HOST}
        proxy.assert_filtered({"upstreamFixture": True, "headers": headers})
        for header in proxy.SENSITIVE:
            with self.subTest(header=header), self.assertRaisesRegex(AssertionError, "upstream received"):
                proxy.assert_filtered({"upstreamFixture": True, "headers": {**headers, header.lower(): "leaked"}})

    def test_websocket_frame_parser(self):
        self.assertEqual(proxy.read_text(io.BytesIO(b"\x81\x02ok")), "ok")
        payload = b"x" * 130
        self.assertEqual(proxy.read_text(io.BytesIO(b"\x81\x7e" + struct.pack("!H", len(payload)) + payload)), payload.decode())
        for frame in [b"\x81\x02x", b"\x81\x82xx", b"\x81\x7f" + struct.pack("!Q", 65537)]:
            with self.assertRaises(AssertionError):
                proxy.read_text(io.BytesIO(frame))


if __name__ == "__main__":
    unittest.main()
