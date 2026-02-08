#!/usr/bin/env python3
import os
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).parent
SRC_DIR = ROOT / "Sources"
PKG = ROOT / "Package.swift"
APP = ROOT / "dist/ImessageStatsMacApp.app"
BUILD = ROOT / "build_app.sh"

POLL_SECONDS = 0.7


def snapshot():
    times = {}
    for path in [SRC_DIR, PKG]:
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


def build_app():
    subprocess.check_call([str(BUILD)], cwd=ROOT)


def quit_app():
    subprocess.run(["/usr/bin/osascript", "-e", 'tell application "ImessageStatsMacApp" to quit'], check=False)
    time.sleep(0.6)
    subprocess.run(["/usr/bin/pkill", "-x", "ImessageStatsMacApp"], check=False)


def open_app():
    if APP.exists():
        subprocess.Popen(["open", "-a", str(APP)])


def main():
    print("Watching for changes… Press Ctrl+C to stop.")
    last = snapshot()
    if not APP.exists():
        build_app()
    quit_app()
    open_app()

    try:
        while True:
            time.sleep(POLL_SECONDS)
            current = snapshot()
            if has_changes(last, current):
                print("Changes detected. Rebuilding app…")
                last = current
                build_app()
                quit_app()
                open_app()
    except KeyboardInterrupt:
        print("Stopping…")


if __name__ == "__main__":
    main()
