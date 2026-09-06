#!/usr/bin/env python3
"""Authenticated release-image lifecycle using the network-local fixture provider."""
import json
from pathlib import Path
import subprocess
import sys
import time
import urllib.error
import urllib.request

TOKEN = "abbey-release-gate-quasar-token"
MARKER = "QUASAR_RELEASE_MANAGER_FIXTURE"


def api(base, path, body=None, token=TOKEN, timeout=180):
    request = urllib.request.Request(
        base + path,
        data=None if body is None else json.dumps(body).encode(),
        headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"},
    )
    # No redirects: mutations must never be silently replayed elsewhere.
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *args, **kwargs):
            return None
    with urllib.request.build_opener(NoRedirect).open(request, timeout=timeout) as response:
        return json.load(response)


def docker(container, *arguments):
    return subprocess.check_output(["docker", "exec", container, *arguments], timeout=120, text=True)


def wait_review(base, site_id):
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        try:
            return api(base, f"/api/sites/{site_id}/plan/review")
        except urllib.error.HTTPError as error:
            if error.code != 404:
                raise
        site = api(base, f"/api/sites/{site_id}")
        if site["status"] == "error":
            raise RuntimeError("fixture planning failed: " + str(site.get("lastError")))
        time.sleep(0.2)
    raise RuntimeError("fixture planning did not produce a review")


def preview_cycle(base, container, site):
    path = f"/api/sites/{site['id']}"
    started = api(base, path + "/preview/start", {})
    assert started["state"] == "running", started
    port = started["port"]
    assert isinstance(port, int) and 1024 <= port <= 65535, started
    html = docker(container, "curl", "--fail", "--silent", "--show-error", "--max-time", "60", f"http://127.0.0.1:{port}/")
    assert MARKER in html, "approved fixture page was not served"
    group_command = ("bun", "/release-fixtures/process-groups.mjs")
    groups = json.loads(docker(container, *group_command, "snapshot", "/data/quasar/sites/" + site["slug"]))
    stopped = api(base, path + "/preview/stop", {})
    assert stopped["state"] == "stopped", stopped
    # Check all /proc members, including zombies, rather than only the former leader.
    remaining = json.loads(docker(container, *group_command, "remaining", json.dumps(groups)))
    assert remaining == [], f"preview groups survived API stop: {remaining}"
    assert api(base, path + "/preview")["state"] == "stopped"
    probe = subprocess.run(
        ["docker", "exec", container, "curl", "--fail", "--silent", "--max-time", "3", f"http://127.0.0.1:{port}/"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10,
    )
    assert probe.returncode == 7, f"preview listener remained or probe failed unexpectedly: {probe.returncode}"
    return groups


def run(phase, base, container, evidence_path):
    capabilities = api(base, "/api/quasar/capabilities")
    if phase == "create":
        try:
            api(base, "/api/sites", token="invalid-fixture-token")
        except urllib.error.HTTPError as error:
            assert error.code == 401, error.code
        else:
            raise AssertionError("Quasar accepted an invalid operator token")
        site = api(base, "/api/sites", {"name": "Release manager fixture", "prompt": "Render the deterministic release fixture page."})
        review = wait_review(base, site["id"])
        assert any(file["path"] == "app/page.tsx" and MARKER in file.get("after", "") for file in review["files"])
        receipt = api(base, f"/api/sites/{site['id']}/plan/approve", {"planDigest": review["planDigest"]})
        assert receipt["planDigest"] == review["planDigest"]
        preparation = api(base, f"/api/sites/{site['id']}/prepare-preview", {}, timeout=900)
        assert preparation["siteID"] == site["id"]
        evidence = {"fixtureProvider": True, "serviceID": capabilities["serviceID"], "site": site, "planDigest": receipt["planDigest"]}
    elif phase == "restart":
        evidence = json.loads(evidence_path.read_text())
        assert capabilities["serviceID"] == evidence["serviceID"], "service identity changed across restart"
        site = api(base, f"/api/sites/{evidence['site']['id']}")
        assert site["status"] == "idle", site
        history = api(base, f"/api/sites/{site['id']}/history")
        assert any(row["kind"] == "mutation" and row["status"] == "succeeded" and row.get("planDigest") == evidence["planDigest"] for row in history), history
        # Preparation admission is process-local; restart must revalidate the
        # persisted reviewed dependency fingerprint before starting a preview.
        preparation = api(base, f"/api/sites/{site['id']}/prepare-preview", {}, timeout=900)
        assert preparation["siteID"] == site["id"]
    else:
        raise ValueError("phase must be create or restart")
    evidence[phase + "StoppedGroups"] = preview_cycle(base, container, site)
    evidence_path.write_text(json.dumps(evidence, indent=2) + "\n")
    print(f"QUASAR_MANAGER_{phase.upper()}_GREEN: fixture planning, real API/installation/render/group absence")
    if phase == "restart":
        print(json.dumps(evidence, sort_keys=True))


if __name__ == "__main__":
    run(sys.argv[1], sys.argv[2], sys.argv[3], Path(sys.argv[4]))
