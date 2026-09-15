# Proxy compatibility probe — 2026-09-13

Status: **Claude desktop proxy compatibility verified for one user-sent test message**.
The user authorized temporary certificate trust and proxy switching. The user sent
the message in Claude and confirmed a normal reply. The test captured a successful
HTTP/2 SSE response, gzip decoding succeeded, and 17 JSON records were parsed with
reply text fields present. None of the allowlisted numeric token-usage fields appeared
in that response. This establishes capture feasibility, not exact token accounting.

Cleanup verified: HTTP/HTTPS and SOCKS point to the original `127.0.0.1:7897`,
the test listener on 8899 stopped, and the exact test certificate is absent from
the login Keychain after deletion with its user trust settings. The Auditor's
production capture remains unchanged; the probe is not connected to its counters.
ChatGPT desktop compatibility was not tested.

## Verified

- Existing upstream `127.0.0.1:7897`: HTTPS request to example.com returned 200.
- Isolated mitmproxy 12.2.3 on `127.0.0.1:8899`, forwarding to that upstream:
  example.com returned 200 when curl explicitly trusted the test CA for that request.
- Excluded example.org returned 200 using normal certificate validation; no probe
  response record was produced for it.
- example.com without explicit CA trust failed with curl certificate error 60.
  The probe recorded a client TLS failure without raw error text.
- Eight probe tests passed: fragmented UTF-8/SSE and byte preservation, bounded
  oversize handling, usage-value validation, compressed stream decoding, invalid
  compression forwarding, Zstandard frames without content size, and redaction.

## Scope and limitations

`scripts/proxy-lab.sh` intercepts only `claude.ai:443` and `example.com:443`.
Other HTTPS destinations pass through encrypted. ChatGPT/OpenAI content is excluded;
this test must not bypass the existing tool restriction on ChatGPT content access.
No certificate-pinning bypass is included. Upstream certificate verification stays enabled.

Requests stream without body inspection. Responses stream unchanged; bounded JSON
or single-line SSE data records are inspected in memory. Only allowlisted numeric
usage fields, text-field presence, counts, status and format categories are written.
No raw text, URLs, IDs, cookies, other headers, flow dumps or HAR files are saved.
gzip, deflate and Brotli are decompressed incrementally in memory; Zstandard uses
a bounded in-memory compressed buffer and parses at response completion. The limits
are 256 KiB compressed buffering for Zstandard, 8 MiB Zstandard window, 2 MiB decoded
data per compressed response, and 64 KiB per JSON record. Multiline SSE JSON is not
supported. Limit hits and decode failures are explicitly marked in metadata.
Empty usage fields mean **unavailable**, never zero tokens. Observed response fields
do not by themselves establish billing totals. A text field may belong to history;
successful live capture requires correlating a deliberately sent test message.

The regular HTTP proxy may be bypassed by an app using SOCKS, direct connections,
or QUIC. No observed request therefore does not prove certificate pinning or an
absence of AI activity. The first app test must diagnose routing separately from TLS.

## Completed app-test procedure

1. Recheck current settings against `.proxy-lab/original-*.txt` and start the listener.
2. Temporarily add the generated test CA to the user's login Keychain with SSL trust.
   This grants certificate authority trust beyond the script's host allowlist;
   it must be removed after testing. A macOS authorization prompt may appear.
3. Temporarily change Ethernet and Wi-Fi HTTP/HTTPS proxies from
   `127.0.0.1:7897` to `127.0.0.1:8899`. Leave SOCKS and bypass lists unchanged.
4. Have the user send one nonsensitive message in Claude. Do not send messages on
   their behalf without explicit permission. Inspect sanitized metadata for routing,
   TLS, live response format and actual numeric usage fields.
5. Restore the original settings and delete this exact certificate using
   `bash scripts/restore-proxy-lab.sh`, then stop the identified test listener.
   Verify proxy settings and certificate removal. `scripts/proxy_lab_session.py`
   supervises this test with an eight-minute timeout and a `stop-requested` file;
   its cleanup restores settings, deletes this certificate, then stops the proxy.
   This test ended through the stop file before the timeout; session status is restored.

Test CA SHA-256:
`FBDCFFAB513726383AF14F18294A9177B5EB9A8859E7A3FADADAF9EEA2C8A2DE`

Runtime, private CA key, original settings and sanitized report live under the
git-ignored `.proxy-lab/`. Do not publish or package that directory.
Restore script is specific to this machine and this certificate; regenerate it
if the original settings or CA change. It refuses to overwrite unexpected settings.
