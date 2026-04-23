#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
cd "$SCRIPT_DIR"
exec /usr/bin/swift -F/System/Library/PrivateFrameworks -framework MultitouchSupport SwipeToVSCode.swift
