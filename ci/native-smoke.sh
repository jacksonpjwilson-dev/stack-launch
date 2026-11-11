#!/bin/bash
set -euo pipefail
stack_device_id=$(xcrun simctl list devices available -j | python3 -c 'import json,sys; d=json.load(sys.stdin); print(next(v["udid"] for k,vs in d["devices"].items() if "iOS" in k for v in vs if v.get("isAvailable") and "iPhone" in v["name"]))')
xcrun simctl boot "$stack_device_id" || true
xcrun simctl bootstatus "$stack_device_id" -b
xcrun simctl install "$stack_device_id" /tmp/StackDerivedData/Build/Products/Debug-iphonesimulator/Stack.app
xcrun simctl launch --terminate-running-process "$stack_device_id" dev.stack.finance
mkdir -p /tmp/StackScreenshots
xcrun simctl io "$stack_device_id" screenshot /tmp/StackScreenshots/overview.png
