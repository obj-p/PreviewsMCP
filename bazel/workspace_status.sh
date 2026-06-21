#!/usr/bin/env bash
set -euo pipefail
echo "STABLE_GIT_VERSION $(git describe --tags --always | sed 's/^v//')"
