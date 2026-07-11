#!/bin/sh
# Build the #254 macOS layer-hosting spike (producer + consumer).
set -eu
cd "$(dirname "$0")"
CFLAGS="-fobjc-arc -framework AppKit -framework QuartzCore -framework CoreGraphics"
clang $CFLAGS -o producer producer.m
clang $CFLAGS -o consumer consumer.m
echo "built: producer consumer"
