#!/usr/bin/env python3
"""P0-1b: Hidden-PTY interactive codex ping probe (pyte screen emulator).

Drives the official codex CLI interactive TUI through a PTY and renders the
screen with pyte so TUI state (composer, trust prompts, responses) is legible.
Validates PTY driving + isolated CODEX_HOME session creation.

Run with Python (pyte installed):
  python3 pty_ping.py \
      <codex_home> <work_dir> [prompt]
"""
import fcntl
import os
import pty
import select
import struct
import subprocess
import sys
import termios
import time

import pyte

CODEX = os.environ["KEEPER_PROBE_CODEX"]
COLS, ROWS = 120, 30


class TUI:
    def __init__(self, fd: int):
        self.fd = fd
        self.screen = pyte.Screen(COLS, ROWS)
        self.stream = pyte.ByteStream(self.screen)

    def pump(self, idle_sec: float, timeout: float) -> None:
        last = time.time()
        start = last
        while time.time() - start < timeout:
            r, _, _ = select.select([self.fd], [], [], 0.3)
            if r:
                try:
                    chunk = os.read(self.fd, 65536)
                except OSError:
                    return
                if not chunk:
                    return
                self.stream.feed(chunk)
                last = time.time()
            elif time.time() - last >= idle_sec:
                return

    def text(self) -> str:
        return "\n".join(line.rstrip() for line in self.screen.display)


def main() -> int:
    codex_home, work_dir = sys.argv[1], sys.argv[2]
    prompt = sys.argv[3] if len(sys.argv) > 3 else "ok"

    master, slave = pty.openpty()
    # PTY defaults to 0x0 winsize — the TUI would wrap every character.
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
    env = dict(os.environ, CODEX_HOME=codex_home, TERM="xterm-256color")
    proc = subprocess.Popen(
        [CODEX, "-C", work_dir],
        stdin=slave, stdout=slave, stderr=slave,
        env=env, cwd=work_dir,
    )
    os.close(slave)
    tui = TUI(master)

    try:
        # Phase 1: wait for TUI boot; auto-accept trust/onboarding prompts
        boot_deadline = time.time() + 40
        while time.time() < boot_deadline:
            tui.pump(idle_sec=1.5, timeout=5)
            text = tui.text().lower()
            if "trust" in text and ("enter" in text or "yes" in text):
                os.write(master, b"\r")
                continue
            if text.strip():
                # screen populated; give it one more idle cycle to settle
                tui.pump(idle_sec=2.5, timeout=8)
                break

        before = tui.text()
        print("=== screen after boot ===")
        print(before)
        print("=" * 40)

        # Phase 2: send ping, wait for response.
        # Type text first, then submit with a separate Enter keystroke —
        # a single combined write can race the TUI event loop.
        os.write(master, prompt.encode())
        time.sleep(0.6)
        os.write(master, b"\r")
        tui.pump(idle_sec=18.0, timeout=150)

        after = tui.text()
        print("=== screen after ping ===")
        print(after)
        print("=" * 40)

        # Fallback: some TUIs want LF instead of CR
        if "ok" in after.split("gpt-5.6-luna low")[0].split("›")[-1].strip()[:2]:
            print("(CR did not submit; retrying with LF)")
            os.write(master, b"\n")
            tui.pump(idle_sec=18.0, timeout=150)
            after = tui.text()
            print("=== screen after LF retry ===")
            print(after)
            print("=" * 40)

        # Phase 3: quit (Ctrl-C twice)
        os.write(master, b"\x03")
        time.sleep(1.0)
        os.write(master, b"\x03")
        tui.pump(idle_sec=2.0, timeout=8)
    finally:
        try:
            proc.terminate()
            proc.wait(timeout=5)
        except Exception:
            proc.kill()
        os.close(master)

    print("=== exit code:", proc.returncode, "===")
    return 0


if __name__ == "__main__":
    sys.exit(main())
