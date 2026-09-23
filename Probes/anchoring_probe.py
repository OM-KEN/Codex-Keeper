#!/usr/bin/env python3
"""P0-1: 5h window anchoring probe (run right after a window expires).

Flow:
  1. Read the latest rate_limits snapshot from the MAIN codex home rollouts.
     If an active (unexpired) 5h window exists, exit INCONCLUSIVE — someone
     already anchored a new window and the test cannot distinguish sources.
  2. Fire a headless `codex exec` ping in the ISOLATED home, then read the
     isolated rollout: if resets_at moved to ~now+5h, exec anchoring works.
  3. Otherwise drive the interactive TUI ping via pty_ping.py and re-check:
     if resets_at now moved, only PTY anchoring works.

Prints a single VERDICT line: INCONCLUSIVE / EXEC-ANCHORS / PTY-ANCHORS / BOTH-FAILED.
"""
import datetime
import glob
import json
import os
import subprocess
import sys
import time

CODEX = os.environ["KEEPER_PROBE_CODEX"]
VENV_PY = sys.executable
PTY_PING = os.path.join(os.path.dirname(os.path.abspath(__file__)), "pty_ping.py")
ISO = os.environ["KEEPER_PROBE_HOME"]
WORKDIR = os.environ["KEEPER_PROBE_WORKDIR"]
MAIN_HOME = os.path.expanduser(os.environ.get("CODEX_HOME", "~/.codex"))
WINDOW_TOLERANCE_MIN = 45  # resets_at should be ~now+300min; allow slack


def latest_main_snapshot():
    files = sorted(glob.glob(MAIN_HOME + "/sessions/**/*.jsonl", recursive=True),
                   key=os.path.getmtime)
    for path in reversed(files[-6:]):
        snap = None
        try:
            for line in open(path):
                if "rate_limits" not in line:
                    continue
                try:
                    d = json.loads(line)
                except Exception:
                    continue
                rl = d.get("payload", {}).get("rate_limits") or {}
                p = rl.get("primary")
                if p and p.get("resets_at"):
                    snap = (d.get("timestamp"), p)
        except Exception:
            continue
        if snap:
            return snap
    return None


def latest_iso_snapshot():
    files = sorted(glob.glob(ISO + "/sessions/**/*.jsonl", recursive=True),
                   key=os.path.getmtime)
    for path in reversed(files[-4:]):
        snap = None
        try:
            for line in open(path):
                if "rate_limits" not in line:
                    continue
                try:
                    d = json.loads(line)
                except Exception:
                    continue
                rl = d.get("payload", {}).get("rate_limits") or {}
                p = rl.get("primary")
                if p and p.get("resets_at"):
                    snap = (d.get("timestamp"), p)
        except Exception:
            continue
        if snap:
            return snap
    return None


def fmt(epoch):
    return datetime.datetime.fromtimestamp(epoch).strftime("%H:%M:%S")


def anchored(now, resets_at) -> bool:
    delta = resets_at - now
    return (300 - WINDOW_TOLERANCE_MIN) * 60 <= delta <= 310 * 60


def exec_ping():
    env = dict(os.environ, CODEX_HOME=ISO)
    subprocess.run(
        [CODEX, "exec", "-C", WORKDIR, "ok"],
        env=env, cwd=WORKDIR,
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=120,
    )


def pty_ping():
    subprocess.run(
        [VENV_PY, PTY_PING, ISO, WORKDIR, "ok"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=240,
    )


def main() -> int:
    now = time.time()

    main_snap = latest_main_snapshot()
    if main_snap:
        ts, p = main_snap
        print(f"main-home snapshot @ {ts}: 5h={p.get('used_percent')}% reset={fmt(p['resets_at'])}")
        if p["resets_at"] > now and (p.get("used_percent") or 0) < 100:
            print("VERDICT: INCONCLUSIVE (active 5h window already anchored by someone else)")
            return 0
    else:
        print("main-home snapshot: none found (treating as no active window)")

    print("firing exec ping...")
    exec_ping()
    time.sleep(2)
    snap = latest_iso_snapshot()
    now = time.time()
    if snap and anchored(now, snap[1]["resets_at"]):
        print(f"after exec ping: reset={fmt(snap[1]['resets_at'])} used={snap[1].get('used_percent')}%")
        print("VERDICT: EXEC-ANCHORS")
        return 0
    if snap:
        print(f"after exec ping: reset={fmt(snap[1]['resets_at'])} used={snap[1].get('used_percent')}% (not newly anchored)")

    print("firing PTY ping...")
    pty_ping()
    time.sleep(2)
    snap = latest_iso_snapshot()
    now = time.time()
    if snap and anchored(now, snap[1]["resets_at"]):
        print(f"after PTY ping: reset={fmt(snap[1]['resets_at'])} used={snap[1].get('used_percent')}%")
        print("VERDICT: PTY-ANCHORS")
        return 0
    if snap:
        print(f"after PTY ping: reset={fmt(snap[1]['resets_at'])} used={snap[1].get('used_percent')}%")
    print("VERDICT: BOTH-FAILED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
