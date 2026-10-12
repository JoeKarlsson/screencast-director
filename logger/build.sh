#!/usr/bin/env bash
# Builds the input logger. Needs the Xcode command line tools (swiftc).
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p bin
swiftc -O InputLogger.swift -o bin/input-logger
echo "built logger/bin/input-logger"
