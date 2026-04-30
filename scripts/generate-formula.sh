#!/bin/bash
# Generates a Homebrew formula for previewsmcp
# Usage: generate-formula.sh <version> <url> <sha256>
set -euo pipefail

VERSION="$1"
URL="$2"
SHA256="$3"

cat <<EOF
class Previewsmcp < Formula
  desc "SwiftUI preview renderer with MCP server for AI-driven UI development"
  homepage "https://github.com/obj-p/PreviewsMCP"
  license "MIT"
  version "${VERSION}"

  url "${URL}"
  sha256 "${SHA256}"

  depends_on :macos

  def install
    bin.install "previewsmcp"
  end

  def post_install
    # Kill any daemon left over from a previous Homebrew-installed
    # version so it can't receive requests from the newly-upgraded
    # CLI. The in-binary version handshake (issue #142) covers this
    # case too — this hook is defense-in-depth that short-circuits
    # the handshake's kill+respawn sequence when brew is the install
    # path. Ignores failure: a wedged daemon that won't respond to
    # SIGTERM must not fail \`brew upgrade\`; the handshake will
    # surface a clear error on the next CLI invocation.
    system bin/"previewsmcp", "kill-daemon", "--timeout", "5" rescue nil
  end

  def caveats
    <<~EOS
      previewsmcp requires Xcode 16+ to compile SwiftUI previews at runtime.
      For iOS simulator support, Apple Silicon is required.
    EOS
  end

  test do
    assert_match "SwiftUI previews", shell_output("#{bin}/previewsmcp --help")
  end
end
EOF
