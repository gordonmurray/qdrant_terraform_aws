#!/usr/bin/env python3
"""Exercise the production REST endpoint using the existing qdrant-canary collection."""
import argparse
import json
import os
import socket
import ssl
import sys
import time
import uuid
from urllib.error import HTTPError
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, HTTPSHandler, Request, build_opener


class NoRedirect(HTTPRedirectHandler):
    # Never forward an API key to a redirected host.
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def check(endpoint, key, runner, timeout=10):
    parsed = urlsplit(endpoint)
    if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise ValueError("Use an HTTPS endpoint without credentials, query parameters or fragments")
    opener = build_opener(NoRedirect(), HTTPSHandler(context=ssl.create_default_context()))

    def request(method, path, data=None):
        body = None if data is None else json.dumps(data).encode()
        req = Request(endpoint.rstrip("/") + path, body, method=method,
                      headers={"api-key": key, "Content-Type": "application/json"})
        with opener.open(req, timeout=timeout) as response:
            return json.load(response)

    point_id = str(uuid.uuid5(uuid.NAMESPACE_DNS, "qdrant-client-canary:" + runner))
    nonce = str(uuid.uuid4())
    base = "/collections/qdrant-canary/points"
    result = request("PUT", base + "?wait=true", {"points": [{
        "id": point_id, "vector": [1, 0, 0, 0], "payload": {"nonce": nonce},
    }]})
    if result.get("result", {}).get("status") != "completed":
        raise ValueError("Canary write did not complete")
    result = request("GET", base + "/" + point_id + "?consistency=majority")
    if result.get("result", {}).get("payload", {}).get("nonce") != nonce:
        raise ValueError("Canary read returned stale or missing data")
    result = request("POST", base + "/query?consistency=majority", {
        "query": [1, 0, 0, 0], "filter": {"must": [{"has_id": [point_id]}]},
        "limit": 1, "with_payload": True,
    })
    points = result.get("result", {}).get("points", [])
    if len(points) != 1 or points[0].get("payload", {}).get("nonce") != nonce:
        raise ValueError("Canary query returned stale or missing data")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--endpoint", default=os.environ.get("QDRANT_URL"))
    parser.add_argument("--runner", default=socket.gethostname(), help="Stable unique runner name")
    parser.add_argument("--timeout", type=float, default=10)
    args = parser.parse_args()
    key = os.environ.get("QDRANT_API_KEY")
    if not args.endpoint or not key or args.timeout <= 0:
        parser.error("Set QDRANT_URL and QDRANT_API_KEY, and use a positive timeout")
    started = time.monotonic()
    error = None
    try:
        check(args.endpoint, key, args.runner, args.timeout)
    except HTTPError as exc:
        error = f"HTTP {exc.code}"
    except Exception as exc:
        # Do not print requests or headers containing credentials.
        error = f"{type(exc).__name__}: {exc}"
    print(json.dumps({"success": error is None, "duration_seconds": round(time.monotonic() - started, 3), "error": error}))
    return 1 if error else 0


if __name__ == "__main__":
    sys.exit(main())
