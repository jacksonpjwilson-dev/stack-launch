#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if ! command -v node >/dev/null; then echo 'Install Node.js LTS (22 or newer) from https://nodejs.org then reopen this launcher.'; read -r; exit 1; fi
if [[ "${1:-}" == "setup" ]]; then node bmo-test/setup.mjs; else node bmo-test/server.mjs; fi
