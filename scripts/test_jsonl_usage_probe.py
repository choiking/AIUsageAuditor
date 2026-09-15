import json
from pathlib import Path
import tempfile
import unittest
from jsonl_usage_probe import claude_report, codex_report


def event(n, tokens, last=None):
    return {"timestamp": f"2026-09-15T00:00:{n:02d}Z", "type": "event_msg",
            "payload": {"type": "token_count", "info": {
                "total_token_usage": {"input_tokens": tokens, "cached_input_tokens": tokens // 2,
                                      "output_tokens": 10, "total_tokens": tokens + 10},
                "last_token_usage": last}}}


def meta(identity):
    return {"type": "session_meta", "payload": {"id": identity}}


class UsageProbeTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)

    def file(self, name, rows, tail=b""):
        path = Path(self.directory.name) / name
        path.write_bytes(b"".join(json.dumps(row).encode() + b"\n" for row in rows) + tail)
        return path

    def test_claude_stream_and_fork_dedup(self):
        def row(n, out):
            return {"type": "assistant", "timestamp": f"2026-09-15T00:00:0{n}Z",
                    "requestId": "req", "message": {"id": "msg", "content": "PRIVATE",
                    "usage": {"input_tokens": 2, "output_tokens": out,
                    "cache_creation_input_tokens": 3, "cache_read_input_tokens": 5}}}
        a = self.file("a", [row(1, 1), row(2, 8)])
        b = self.file("b", [row(1, 1), row(2, 8)])
        report = claude_report([a, b])
        self.assertEqual(report["unique_usage_records"], 1)
        self.assertEqual(report["observed_total_tokens"], 18)
        self.assertNotIn("PRIVATE", json.dumps(report))
        self.assertNotIn("req", json.dumps(report["observed_tokens"]))

    def test_codex_cumulative_not_last_usage_sum(self):
        path = self.file("a", [meta("one"), event(1, 100), event(2, 150), event(3, 150)])
        report = codex_report([path])
        self.assertEqual(report["observed_tokens"]["total_tokens"], 160)
        self.assertEqual(report["observed_tokens"]["cached_input_tokens"], 75)
        self.assertEqual(report["unique_usage_increments"], 2)

    def test_claude_conflicting_timestamp_stays_ambiguous(self):
        def row(out):
            return {"type": "assistant", "timestamp": "2026-09-15T00:00:00Z",
                    "requestId": "req", "message": {"id": "msg", "usage": {
                    "input_tokens": 1, "output_tokens": out,
                    "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0}}}
        report = claude_report([self.file("a", [row(1), row(2), row(1)])])
        self.assertEqual(report["unique_usage_records"], 0)
        self.assertEqual(report["diagnostics"]["excluded_ambiguous_messages"], 1)

    def test_codex_copied_fork_prefix(self):
        a = self.file("a", [meta("parent"), event(1, 100)])
        b = self.file("b", [meta("child"), event(1, 100), event(2, 150)])
        report = codex_report([a, b])
        self.assertEqual(report["observed_tokens"]["total_tokens"], 160)
        self.assertEqual(report["diagnostics"]["copied_usage_events"], 1)

    def test_counter_reset_excludes_session(self):
        path = self.file("a", [meta("one"), event(1, 100), event(2, 20)])
        report = codex_report([path])
        self.assertEqual(report["observed_tokens"]["total_tokens"], 0)
        self.assertEqual(report["diagnostics"]["excluded_regressing_sessions"], 1)

    def test_partial_tail_not_consumed(self):
        path = self.file("a", [meta("one"), event(1, 100)], json.dumps(event(2, 150)).encode())
        report = codex_report([path])
        self.assertEqual(report["observed_tokens"]["total_tokens"], 110)
        self.assertEqual(report["diagnostics"]["unfinished_tail_lines"], 1)

    def test_rate_limit_only_event_and_invalid_usage(self):
        path = self.file("a", [meta("one"), {"type": "event_msg", "payload": {
            "type": "token_count", "info": None}}, event(1, -1)])
        report = codex_report([path])
        self.assertEqual(report["unique_usage_increments"], 0)
        self.assertEqual(report["diagnostics"]["no_usage_info"], 1)
        self.assertEqual(report["diagnostics"]["excluded_incomplete_records"], 1)


if __name__ == "__main__":
    unittest.main()
