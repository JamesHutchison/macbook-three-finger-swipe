#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
cd "$SCRIPT_DIR"
exec /usr/bin/swift -F/System/Library/PrivateFrameworks -framework MultitouchSupport SwipeToVSCode.swift
