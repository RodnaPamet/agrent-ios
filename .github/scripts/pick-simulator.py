#!/usr/bin/env python3
"""Print the UDID of the newest available iPhone simulator.

Runner images change their Xcode and device sets without notice, so the test
destination is discovered rather than pinned. Hardcoding a device name is the
classic CI-only failure: the runner's device set is not the developer's, and
an image update then looks like a code failure.

Deployment target is iOS 17.0, so any iOS 17+ runtime will do; newest is
chosen so CI exercises what a current device would.
"""
import json
import subprocess
import sys


def main() -> int:
    raw = subprocess.run(
        ["xcrun", "simctl", "list", "devices", "available", "--json"],
        capture_output=True, text=True, check=True,
    ).stdout
    devices = json.loads(raw)["devices"]

    best = None
    for runtime, entries in devices.items():
        if "iOS" not in runtime:
            continue
        version = tuple(
            int(part) for part in runtime.split("iOS-")[-1].split("-") if part.isdigit()
        )
        for device in entries:
            if device.get("isAvailable") and device["name"].startswith("iPhone"):
                if best is None or version > best[0]:
                    best = (version, device["udid"], device["name"], runtime)

    if best is None:
        print("No available iPhone simulator on this runner.", file=sys.stderr)
        print("Runtimes seen: " + ", ".join(devices), file=sys.stderr)
        return 1

    _, udid, name, runtime = best
    print(f"Selected {name} on {runtime}", file=sys.stderr)
    print(udid)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
