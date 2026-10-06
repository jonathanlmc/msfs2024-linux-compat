#!/usr/bin/env python3
"""Apply FSDT hotfix files staged by the Addon Manager updater.

Usage: apply_hotfix.py <path-to-proton-pfx>

Reads <pfx>/drive_c/users/*/AppData/Roaming/Virtuali/hotfix_pending.json and copies
every staged file to its group's install root. This is exactly what the updater's
apply step does when it runs; run it when hotfix_pending.json is stuck at
"status": "pending" (engine aborts with an opaque Python error).
"""
import json
import os
import shutil
import sys


def win2unix(path: str, pfx: str) -> str:
    # C:\foo\bar -> <pfx>/drive_c/foo/bar  (drive_c already contains users/<user>)
    return pfx + "/drive_c" + path[2:].replace("\\", "/")


def find_manifest(pfx: str) -> str:
    users = os.path.join(pfx, "drive_c", "users")
    for user in os.listdir(users):
        m = os.path.join(users, user, "AppData", "Roaming", "Virtuali", "hotfix_pending.json")
        if os.path.exists(m):
            return m
    sys.exit("hotfix_pending.json not found under " + users)


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    pfx = os.path.abspath(sys.argv[1])
    manifest = find_manifest(pfx)
    with open(manifest) as f:
        data = json.load(f)

    copied = missing = 0

    for group in data["groups"]:
        root = win2unix(group["root"], pfx)

        for entry in group["files"]:
            src = win2unix(entry["staged"], pfx)
            dst = os.path.join(root, entry["path"].replace("\\", "/"))
            if not os.path.exists(src):
                print("MISSING", src)
                missing += 1
                continue
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copy2(src, dst)
            copied += 1

    print(f"applied {copied} files ({missing} missing) from {manifest}")


if __name__ == "__main__":
    main()
