#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
swiftc -O -module-cache-path build/mc -o build/peerAddressTest main.swift ../../macos/phase3-tcp/src/PeerAddressPolicy.swift
./build/peerAddressTest
