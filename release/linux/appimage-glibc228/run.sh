#!/usr/bin/env bash
# Build and verify the glibc 2.28 AppImage locally with Docker: the same two container runs the
# `Release · Linux x64 AppImage (glibc 2.28)` workflow performs. On Apple Silicon the x86_64
# container runs under emulation, which is slower than the GitHub runner.
set -euo pipefail
# The script lives three levels below the repository root.
root="$(cd "$(dirname "$0")/../../.." && pwd)"
image=almalinux:8.10

docker pull --platform linux/amd64 "$image"
run() { docker run --rm --platform linux/amd64 -v "$root":/src -w /src "$@"; }

run -e GITHUB_TOKEN "$image" bash release/linux/appimage-glibc228/build.sh
# A fresh container without build tools proves the AppImage runs on a bare glibc 2.28 system.
run "$image" bash release/linux/appimage-glibc228/verify.sh
