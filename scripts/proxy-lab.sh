#!/bin/bash
# Local listener only. Does not change macOS proxy settings or certificate trust.
set -euo pipefail
umask 077
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
lab_dir="$project_dir/.proxy-lab"
mkdir -p "$lab_dir/ca"
export AUDITOR_PROBE_REPORT="$lab_dir/metadata.jsonl"
exec "$lab_dir/runtime/bin/mitmdump" \
  --quiet --flow-detail 0 \
  --mode upstream:http://127.0.0.1:7897 \
  --listen-host 127.0.0.1 --listen-port 8899 \
  --allow-hosts '^(claude\.ai|example\.com):443$' \
  --set "confdir=$lab_dir/ca" \
  --set ssl_insecure=false --set store_streamed_bodies=false \
  --set termlog_verbosity=error \
  --scripts "$project_dir/scripts/proxy_probe.py" \
  >/dev/null 2>&1
