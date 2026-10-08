#!/usr/bin/env python3
"""Host proof: synthetic temporary stores, exact child PID SIGKILL, fresh reader."""
import pathlib
import signal
import subprocess
import sys
import tempfile
import time

binary = pathlib.Path(sys.argv[1]).resolve()
source = pathlib.Path(sys.argv[2]).resolve()
for kind in ("workout", "variant", "activation"):
    for phase, expected in (("before_save", 0), ("after_commit", 1)):
        with tempfile.TemporaryDirectory(prefix="plenty-crash-") as directory:
            setup = "setup" if kind == "workout" else f"setup-{kind}"
            commit = "commit" if kind == "workout" else f"commit-{kind}"
            verify = "verify" if kind == "workout" else f"verify-{kind}"
            subprocess.run([str(binary), setup, directory, str(source)], check=True)
            child = subprocess.Popen([str(binary), commit, directory, str(source), phase])
            try:
                deadline = time.monotonic() + 30
                marker = pathlib.Path(directory) / "marker"
                while not marker.exists():
                    if child.poll() is not None:
                        raise RuntimeError(f"child exited before marker: {child.returncode}")
                    if time.monotonic() > deadline:
                        raise TimeoutError("commit marker not reached")
                    time.sleep(0.02)
                assert marker.read_text() == phase
                # SIGKILL only the exact child we launched; never discover or kill others.
                child.send_signal(signal.SIGKILL)
                assert child.wait(timeout=10) == -signal.SIGKILL
                print(f"SIGKILL PROOF {kind} {phase} child PID={child.pid}", flush=True)
                subprocess.run([str(binary), verify, directory, str(source), str(expected)], check=True)
            finally:
                if child.poll() is None:
                    child.kill()
                    child.wait(timeout=10)
print("6/6 macOS process-kill/reopen proofs passed; this is not an iOS process-kill claim.")
