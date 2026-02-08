#!/usr/bin/env python3
import os
import subprocess
import sys
import time
from pathlib import Path

WATCH_DIRS = [
    Path(__file__).parent / "Sources",
    Path(__file__).parent / "Package.swift",
]

POLL_SECONDS = 0.7


def snapshot():
    times = {}
    for path in WATCH_DIRS:
        if path.is_file():
            times[str(path)] = path.stat().st_mtime
        elif path.is_dir():
            for root, _, files in os.walk(path):
                for name in files:
                    if name.endswith((".swift", ".plist")):
                        p = Path(root) / name
                        try:
                            times[str(p)] = p.stat().st_mtime
                        except FileNotFoundError:
                            continue
    return times


def has_changes(old, new):
    if old.keys() != new.keys():
        return True
    for k, v in new.items():
        if old.get(k) != v:
            return True
    return False


def run_app():
    return subprocess.Popen(["swift", "run"], cwd=Path(__file__).parent)


def main():
    print("Watching for changes… Press Ctrl+C to stop.")
    last = snapshot()
    proc = run_app()
    try:
        while True:
            time.sleep(POLL_SECONDS)
            current = snapshot()
            if has_changes(last, current):
                print("Changes detected. Restarting…")
                last = current
                proc.terminate()
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.kill()
                proc = run_app()
    except KeyboardInterrupt:
        print("Stopping…")
    finally:
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                proc.kill()


if __name__ == "__main__":
    main()
