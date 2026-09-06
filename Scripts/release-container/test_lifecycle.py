"""Checks that the gate rejects incorrect stop evidence without needing Docker."""
import subprocess
import unittest
from unittest.mock import patch

import lifecycle


class LifecycleChecks(unittest.TestCase):
    site = {"id": "fixture-id", "slug": "fixture-site"}

    def api_result(self, base, path, body=None):
        if path.endswith("/preview/start"):
            return {"state": "running", "port": 4710}
        if path.endswith("/preview/stop") or path.endswith("/preview"):
            return {"state": "stopped"}
        raise AssertionError("unexpected route: " + path)

    def cycle(self, remaining="[]", curl_code=7):
        with patch.object(lifecycle, "api", side_effect=self.api_result) as api, \
             patch.object(lifecycle, "docker", side_effect=[lifecycle.MARKER, "[123]", remaining]) as docker, \
             patch.object(lifecycle.subprocess, "run", return_value=subprocess.CompletedProcess([], curl_code)):
            result = lifecycle.preview_cycle("http://127.0.0.1:1234", "fixture-container", self.site)
            self.assertEqual(result, [123])
            self.assertEqual(api.call_args_list[1].args[1], "/api/sites/fixture-id/preview/stop")
            self.assertEqual(docker.call_args_list[-1].args[-2:], ("remaining", "[123]"))

    def test_requires_api_stop_and_group_absence(self):
        self.cycle()

    def test_rejects_zombie_group_after_api_stop(self):
        with self.assertRaisesRegex(AssertionError, "groups survived"):
            self.cycle('[{"pid":123,"group":123,"state":"Z"}]')

    def test_rejects_remaining_listener(self):
        with self.assertRaisesRegex(AssertionError, "listener remained"):
            self.cycle(curl_code=0)

    def test_rejects_timeout_as_proof_of_listener_absence(self):
        with self.assertRaisesRegex(AssertionError, "listener remained"):
            self.cycle(curl_code=28)

    def test_rejects_wrong_rendered_page(self):
        with patch.object(lifecycle, "api", side_effect=self.api_result), \
             patch.object(lifecycle, "docker", return_value="wrong page"):
            with self.assertRaisesRegex(AssertionError, "not served"):
                lifecycle.preview_cycle("http://127.0.0.1:1234", "fixture-container", self.site)


if __name__ == "__main__":
    unittest.main()
