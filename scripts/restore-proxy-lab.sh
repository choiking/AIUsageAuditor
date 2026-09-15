#!/bin/bash
# Restore this machine's captured HTTP/HTTPS settings after an approved test.
# Does not touch SOCKS, PAC, bypass domains, or unrelated certificates.
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
for service in Ethernet Wi-Fi; do
  for kind in web secureweb; do
    current="$(/usr/sbin/networksetup "-get${kind}proxy" "$service")"
    if [[ "$current" != $'Enabled: Yes\nServer: 127.0.0.1\nPort: 8899\nAuthenticated Proxy Enabled: 0' &&
          "$current" != $'Enabled: Yes\nServer: 127.0.0.1\nPort: 7897\nAuthenticated Proxy Enabled: 0' ]]; then
      echo "Settings changed outside this test; inspect $service $kind before restoring." >&2
      exit 1
    fi
  done
done
for service in Ethernet Wi-Fi; do
  /usr/sbin/networksetup -setwebproxy "$service" 127.0.0.1 7897
  /usr/sbin/networksetup -setsecurewebproxy "$service" 127.0.0.1 7897
  /usr/sbin/networksetup -setwebproxystate "$service" on
  /usr/sbin/networksetup -setsecurewebproxystate "$service" on
done
# Delete by this test CA's exact fingerprint, never by the generic mitmproxy name.
/usr/bin/security delete-certificate -t \
  -Z FBDCFFAB513726383AF14F18294A9177B5EB9A8859E7A3FADADAF9EEA2C8A2DE \
  "$HOME/Library/Keychains/login.keychain-db"
echo "Original HTTP/HTTPS proxy settings restored; test certificate removed."
