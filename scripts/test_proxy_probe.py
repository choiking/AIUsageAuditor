import json
import tempfile
import os
import unittest
import gzip
import brotli
import zstandard
from pathlib import Path
from types import SimpleNamespace
from proxy_probe import Inspector, Probe, LIMIT


class ProbeTests(unittest.TestCase):
    def test_zstd_stream_without_content_size(self):
        probe = Inspector("json", "zstd")
        raw = json.dumps({"text": "x" * 20000, "usage": {"output_tokens": 5}}).encode()
        wire = zstandard.ZstdCompressor(write_content_size=False).compress(raw)
        self.assertEqual(probe.stream(wire), wire)
        probe.stream(b"")
        self.assertEqual(probe.report["decode_status"], "ok")
        self.assertEqual(probe.report["usage"], {"output_tokens": 5})

    def test_compressed_fragmented_stream(self):
        raw = b'data: {"delta":{"text":"PRIVATE"},"usage":{"output_tokens":7}}\n\n'
        for encoding, encode in (("gzip", gzip.compress), ("br", brotli.compress),
                                 ("zstd", zstandard.ZstdCompressor().compress)):
            with self.subTest(encoding=encoding):
                probe = Inspector("sse", encoding)
                wire = encode(raw)
                forwarded = b"".join(probe.stream(wire[i:i+1]) for i in range(len(wire)))
                probe.stream(b"")
                self.assertEqual(forwarded, wire)
                self.assertEqual(probe.report["usage"], {"output_tokens": 7})
                self.assertEqual(probe.report["bytes"], len(wire))
                self.assertEqual(probe.report["decode_status"], "ok")
                self.assertNotIn("PRIVATE", json.dumps(probe.report))

    def test_bad_compression_is_forwarded(self):
        probe = Inspector("sse", "gzip")
        wire = b"invalid private bytes"
        self.assertEqual(probe.stream(wire), wire)
        self.assertEqual(probe.report["decode_status"], "failed")

    def test_fragmented_utf8_sse_preserves_bytes_and_redacts(self):
        raw = ('data: ' + json.dumps({"delta": {"text": "秘密 PRIVATE"},
               "usage": {"input_tokens": 17, "output_tokens": 9}}, ensure_ascii=False)
               + '\r\n\r\n').encode()
        probe = Inspector("sse")
        forwarded = b"".join(probe.stream(raw[i:i+1]) for i in range(len(raw)))
        self.assertEqual(forwarded, raw)
        probe.stream(b"")
        self.assertTrue(probe.report["text_field_present"])
        self.assertEqual(probe.report["usage"], {"input_tokens": 17, "output_tokens": 9})
        self.assertNotIn("PRIVATE", json.dumps(probe.report))
        self.assertEqual(probe.report["json_records"], 1)

    def test_oversize_recovers_at_next_line(self):
        probe = Inspector("sse")
        probe.stream(b'data: ' + b'x' * (LIMIT * 2))
        self.assertLessEqual(len(probe.buffer), LIMIT)
        probe.stream(b'\ndata: {"usage":{"output_tokens":3}}\n')
        self.assertEqual(probe.report["oversize_records"], 1)
        self.assertEqual(probe.report["usage"], {"output_tokens": 3})

    def test_json_rejects_non_numeric_and_negative_usage(self):
        probe = Inspector("json")
        probe.stream(b'{"usage":{"input_tokens":"SECRET","output_tokens":-4,"total_tokens":true}}')
        probe.stream(b"")
        self.assertEqual(probe.report["usage"], {})

    def test_compression_never_claims_parsing(self):
        probe = Inspector("compressed")
        probe.stream(b'{"output_tokens":999}')
        probe.stream(b"")
        self.assertEqual(probe.report["json_records"], 0)

    def test_addon_does_not_log_headers_paths_or_bodies(self):
        with tempfile.TemporaryDirectory() as directory:
            os.environ["AUDITOR_PROBE_REPORT"] = str(Path(directory) / "out.jsonl")
            probe = Probe()
            flow = SimpleNamespace(id="PRIVATE", request=SimpleNamespace(
                host="claude.ai", path="/PRIVATE", headers={"cookie": "PRIVATE"}),
                response=SimpleNamespace(status_code=200, http_version="HTTP/2",
                headers={"content-type": "application/json", "set-cookie": "PRIVATE"}))
            probe.requestheaders(flow)
            probe.responseheaders(flow)
            self.assertTrue(flow.request.stream)
            flow.response.stream(b'{"text":"PRIVATE","output_tokens":4}')
            probe.response(flow)
            report = Path(os.environ["AUDITOR_PROBE_REPORT"]).read_text()
            self.assertNotIn("PRIVATE", report)
            self.assertEqual(json.loads(report)["usage"], {"output_tokens": 4})
            self.assertEqual(probe.pending, {})


if __name__ == "__main__":
    unittest.main()
