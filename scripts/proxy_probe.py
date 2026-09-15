"""Opt-in Claude compatibility probe. No headers, URLs or text are written.

Run only through proxy-lab.sh, which scopes TLS interception and disables logs.
"""
import json
import os
import time
import zlib
import brotli
import io
import zstandard
from pathlib import Path

HOSTS = {"claude.ai": "claude", "example.com": "public_test"}
USAGE_KEYS = {"input_tokens", "output_tokens", "cache_read_input_tokens",
              "cache_creation_input_tokens", "total_tokens"}
LIMIT = 65536


class Inspector:
    def __init__(self, kind, encoding="identity"):
        self.kind = kind
        self.encoding = encoding
        self.decoded = 0
        self.zstd_buffer = bytearray()
        self.decoder = (zlib.decompressobj(31) if encoding == "gzip" else
                        zlib.decompressobj() if encoding == "deflate" else
                        brotli.Decompressor() if encoding == "br" else None)
        self.disabled = encoding not in {"identity", "gzip", "deflate", "br", "zstd"}
        self.buffer = bytearray()
        self.dropping = False
        self.report = {"bytes": 0, "chunks": 0, "json_records": 0,
                       "text_field_present": False, "usage": {},
                       "oversize_records": 0,
                       "decode_status": "unsupported" if self.disabled else "ok"}

    def inspect(self, raw):
        try:
            value = json.loads(raw)
        except (ValueError, UnicodeError, RecursionError):
            return
        self.report["json_records"] += 1
        pending = [value]
        while pending:
            item = pending.pop()
            if isinstance(item, dict):
                for key, val in item.items():
                    if key in {"text", "completion"} and isinstance(val, str):
                        self.report["text_field_present"] = True
                    if key in USAGE_KEYS and type(val) is int and 0 <= val < 10**12:
                        # Observed fields only: never infer billable usage or sum snapshots.
                        self.report["usage"][key] = val
                    if isinstance(val, (dict, list)):
                        pending.append(val)
            elif isinstance(item, list):
                pending.extend(v for v in item if isinstance(v, (dict, list)))

    def stream(self, chunk):
        if chunk:
            self.report["bytes"] += len(chunk)
            self.report["chunks"] += 1
        if not self.disabled:
            try:
                if self.encoding == "zstd":
                    if len(self.zstd_buffer) + len(chunk) > 256 * 1024:
                        self.zstd_buffer.clear()
                        self.disabled = True
                        self.report["decode_status"] = "size_limit"
                    else:
                        self.zstd_buffer.extend(chunk)
                elif self.decoder is None:
                    self.consume(chunk)
                else:
                    incoming = chunk
                    while True:
                        if self.encoding == "br":
                            decoded = self.decoder.process(incoming, output_buffer_limit=LIMIT)
                            incoming = b""
                            more = not self.decoder.can_accept_more_data()
                        else:
                            decoded = self.decoder.decompress(incoming, LIMIT)
                            incoming = self.decoder.unconsumed_tail
                            more = bool(incoming)
                        self.decoded += len(decoded)
                        if self.decoded > 2 * 1024 * 1024:
                            self.disabled = True
                            self.buffer.clear()
                            self.report["decode_status"] = "size_limit"
                            break
                        if decoded:
                            self.consume(decoded)
                        if not more:
                            break
            except (zlib.error, brotli.error):
                self.disabled = True
                self.buffer.clear()
                self.report["decode_status"] = "failed"
        if not chunk:
            self.finish()
        return chunk

    def consume(self, chunk):
        if self.kind == "sse":
            # Scan lines in bounded pieces; transport chunks may split UTF-8/JSON.
            start = 0
            while start < len(chunk):
                end = chunk.find(b"\n", start)
                stop = len(chunk) if end < 0 else end
                if not self.dropping:
                    if len(self.buffer) + stop - start > LIMIT:
                        self.buffer.clear()
                        self.dropping = True
                        self.report["oversize_records"] += 1
                    else:
                        self.buffer.extend(chunk[start:stop])
                if end < 0:
                    break
                if not self.dropping and self.buffer.startswith(b"data:"):
                    self.inspect(bytes(self.buffer[5:]).strip())
                self.buffer.clear()
                self.dropping = False
                start = end + 1
        elif self.kind == "json" and not self.dropping:
            if len(self.buffer) + len(chunk) > LIMIT:
                self.buffer.clear()
                self.dropping = True
                self.report["oversize_records"] += 1
            else:
                self.buffer.extend(chunk)

    def finish(self):
        if self.zstd_buffer and not self.disabled:
            try:
                with zstandard.ZstdDecompressor(max_window_size=8 * 1024 * 1024).stream_reader(
                        io.BytesIO(self.zstd_buffer)) as reader:
                    while decoded := reader.read(LIMIT):
                        self.decoded += len(decoded)
                        if self.decoded > 2 * 1024 * 1024:
                            self.disabled = True
                            self.buffer.clear()
                            self.report["decode_status"] = "size_limit"
                            break
                        self.consume(decoded)
            except zstandard.ZstdError:
                self.disabled = True
                self.buffer.clear()
                self.report["decode_status"] = "failed"
            finally:
                self.zstd_buffer.clear()
        if not self.dropping and self.buffer:
            if self.kind == "json":
                self.inspect(bytes(self.buffer))
            elif self.kind == "sse" and self.buffer.startswith(b"data:"):
                self.inspect(bytes(self.buffer[5:]).strip())
        self.buffer.clear()


class Probe:
    def __init__(self):
        self.pending = {}

    def emit(self, record):
        record = {"time": int(time.time()), **record}
        target = Path(os.environ["AUDITOR_PROBE_REPORT"])
        fd = os.open(target, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
        with os.fdopen(fd, "a") as out:
            out.write(json.dumps(record, sort_keys=True) + "\n")

    def requestheaders(self, flow):
        flow.request.stream = True

    def responseheaders(self, flow):
        flow.response.stream = True
        app = HOSTS.get(flow.request.host)
        if app is None:
            return
        mime = flow.response.headers.get("content-type", "").split(";", 1)[0].lower()
        kind = {"text/event-stream": "sse", "application/json": "json"}.get(mime, "other")
        encoding = flow.response.headers.get("content-encoding", "identity").strip().lower()
        compressed = encoding != "identity"
        inspector = Inspector(kind, encoding)
        record = {"event": "response", "app": app,
                  "status": flow.response.status_code, "format": kind,
                  "compressed": compressed,
                  "encoding": encoding if encoding in {"identity", "gzip", "br", "deflate", "zstd"} else "other",
                  "protocol": flow.response.http_version if flow.response.http_version in
                  {"HTTP/1.0", "HTTP/1.1", "HTTP/2", "HTTP/2.0", "HTTP/3", "HTTP/3.0"} else "other"}
        self.pending[flow.id] = (inspector, record)
        flow.response.stream = inspector.stream

    def response(self, flow):
        entry = self.pending.pop(flow.id, None)
        if entry:
            inspector, record = entry
            inspector.finish()
            self.emit({**record, **inspector.report})

    def error(self, flow):
        entry = self.pending.pop(flow.id, None)
        if entry:
            entry[0].buffer.clear()
        app = HOSTS.get(flow.request.host) if flow.request else None
        if app:
            self.emit({"event": "request_failed", "app": app})

    def tls_established_client(self, data):
        self.tls_event(data, "client_tls_ok")

    def tls_failed_client(self, data):
        self.tls_event(data, "client_tls_failed")

    def tls_failed_server(self, data):
        self.tls_event(data, "server_tls_failed")

    def tls_event(self, data, event):
        app = HOSTS.get(data.context.client.sni)
        if app:
            self.emit({"event": event, "app": app})


addons = [Probe()]
