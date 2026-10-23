import importlib.util
import io
import json
from pathlib import Path
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("client", Path(__file__).resolve().parents[1] / "scripts/check-client.py")
client = importlib.util.module_from_spec(spec)
spec.loader.exec_module(client)


class FakeOpener:
    def __init__(self, stale=False):
        self.nonce = None
        self.requests = []
        self.stale = stale

    def open(self, request, timeout):
        self.requests.append(request)
        if request.method == "PUT":
            self.nonce = json.loads(request.data)["points"][0]["payload"]["nonce"]
            result = {"status": "completed"}
        elif request.method == "GET":
            result = {"payload": {"nonce": "old" if self.stale else self.nonce}}
        else:
            result = {"points": [{"payload": {"nonce": self.nonce}}]}
        return io.BytesIO(json.dumps({"result": result}).encode())


class ClientTests(unittest.TestCase):
    def test_write_read_query_use_tls_and_auth(self):
        opener = FakeOpener()
        with patch.object(client, "build_opener", return_value=opener):
            client.check("https://qdrant.example.com:6333", "secret", "runner")
        self.assertEqual([r.method for r in opener.requests], ["PUT", "GET", "POST"])
        self.assertTrue(all(r.get_header("Api-key") == "secret" for r in opener.requests))

    def test_stale_read_fails(self):
        with patch.object(client, "build_opener", return_value=FakeOpener(stale=True)):
            with self.assertRaisesRegex(ValueError, "stale"):
                client.check("https://qdrant.example.com", "secret", "runner")

    def test_plaintext_and_embedded_credentials_rejected(self):
        for endpoint in ["http://qdrant.example.com", "https://user:pass@qdrant.example.com"]:
            with self.assertRaises(ValueError):
                client.check(endpoint, "secret", "runner")

    def test_redirects_do_not_forward_credentials(self):
        self.assertIsNone(client.NoRedirect().redirect_request(None, None, 302, "", {}, "https://other.example.com"))
