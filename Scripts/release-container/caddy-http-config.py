#!/usr/bin/env python3
"""Keep adapted production routes, substituting only a local plaintext listener."""
import json
from pathlib import Path
import sys


def plaintext(config):
    servers = config["apps"]["http"]["servers"]
    if len(servers) != 1:
        raise ValueError("expected one production HTTPS listener")
    server = next(iter(servers.values()))
    if server["listen"] != [":443"]:
        raise ValueError("unexpected production listener")
    server["listen"] = [":8080"]
    server.pop("tls_connection_policies", None)
    server["automatic_https"] = {"disable": True}
    config["apps"].pop("tls", None)
    return config


if __name__ == "__main__":
    source, destination = map(Path, sys.argv[1:])
    destination.write_text(json.dumps(plaintext(json.loads(source.read_text()))) + "\n")
