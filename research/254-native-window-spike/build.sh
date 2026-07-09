#!/bin/sh
# Build the #254 native-window spikes (see FINDINGS.md).
#   producer_live  -- vends an NSHostingView's layer over a CAContext (does NOT host)
#   consumer       -- hosts a CAContext via CALayerHost (reused from layerhost-spike)
#   agent_native   -- owns a real native window; used for the respawn-handoff test
#   wbounds        -- prints an on-screen window's bounds, for screencapture -R
set -eu
cd "$(dirname "$0")"
swiftc -O producer_live.swift -o producer_live -framework AppKit
swiftc -O agent_native.swift -o agent_native -framework AppKit
swiftc -O wbounds.swift -o wbounds
clang -fobjc-arc -framework AppKit -framework QuartzCore -framework CoreGraphics -o consumer consumer.m
echo "built: producer_live agent_native wbounds consumer"
