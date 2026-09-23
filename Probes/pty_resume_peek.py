#!/usr/bin/env python3
"""P0-4b: peek at `codex resume <id>` for a desktop-origin session.

Opens the session in the interactive TUI (NO prompt is sent, so no quota is
consumed and no turn starts), captures the rendered screen to prove the
history loads, then quits. Read-only with respect to the thread.

  python pty_resume_peek.py <codex_home> <session_uuid>
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


def main() -> int:
    codex_home, session_id = sys.argv[1], sys.argv[2]
    work_dir = sys.argv[3] if len(sys.argv) > 3 else codex_home

    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
    env = dict(os.environ, CODEX_HOME=codex_home, TERM="xterm-256color")
    proc = subprocess.Popen(
        [CODEX, "resume", session_id],
        stdin=slave, stdout=slave, stderr=slave,
        env=env, cwd=work_dir,
    )
    os.close(slave)

    screen = pyte.Screen(COLS, ROWS)
    stream = pyte.ByteStream(screen)

    def pump(idle_sec: float, timeout: float) -> None:
        last = time.time()
        start = last
        while time.time() - start < timeout:
            r, _, _ = select.select([master], [], [], 0.3)
            if r:
                try:
                    chunk = os.read(master, 65536)
                except OSError:
                    return
                if not chunk:
                    return
                stream.feed(chunk)
                last = time.time()
            elif time.time() - last >= idle_sec:
                return

    def text() -> str:
        return "\n".join(line.rstrip() for line in screen.display)

    try:
        # Boot; answer pickers (trust / working-directory choice) with Enter
        # = option 1 (session directory), which matches Keeper semantics.
        for _ in range(4):
            pump(idle_sec=3.0, timeout=30)
            t = text().lower()
            if "press enter to continue" in t or "choose working directory" in t:
                os.write(master, b"\r")
                continue
            break
        pump(idle_sec=4.0, timeout=30)
        print("=== resume screen ===")
        print(text())
        print("=" * 40)
        os.write(master, b"\x03")
        time.sleep(1.0)
        os.write(master, b"\x03")
        time.sleep(1.0)
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
