"""Bounded local test session: restore routing and trust on completion/timeout."""
import json
import os
import signal
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LAB = ROOT / ".proxy-lab"
STOP = LAB / "stop-requested"
STATUS = LAB / "session-status.json"


def status(state):
    STATUS.write_text(json.dumps({"state": state, "time": int(time.time())}) + "\n")


def run(*args):
    subprocess.run(args, check=True, stdout=subprocess.DEVNULL,
                   stderr=subprocess.DEVNULL, timeout=30)


def stop(signum, frame):
    STOP.touch()


if __name__ == "__main__":
    os.umask(0o077)
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    STOP.unlink(missing_ok=True)
    proxy_pid = int(os.environ["AUDITOR_TEST_PROXY_PID"])
    status("starting")
    try:
        for service in ("Ethernet", "Wi-Fi"):
            for kind in ("web", "secureweb"):
                run("/usr/sbin/networksetup", f"-set{kind}proxy", service,
                    "127.0.0.1", "8899")
                run("/usr/sbin/networksetup", f"-set{kind}proxystate", service, "on")
        status("ready")
        deadline = time.monotonic() + 480
        while not STOP.exists() and time.monotonic() < deadline:
            time.sleep(1)
    finally:
        status("restoring")
        try:
            run("/bin/bash", str(ROOT / "scripts/restore-proxy-lab.sh"))
        except Exception:
            # Preserve the listener if routing could not be restored.
            status("restore_failed")
            raise SystemExit(1)
        else:
            try:
                os.kill(proxy_pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            status("restored")
