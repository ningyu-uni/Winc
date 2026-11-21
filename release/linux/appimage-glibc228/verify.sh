#!/usr/bin/env bash
# Verify a built glibc 2.28 AppImage in a pristine environment: a fresh AlmaLinux 8 container
# with no build tooling, only the repository mounted. This proves the AppImage runs on a bare
# glibc 2.28 system, not just on the machine that built it.
#
# Usage: bash release/linux/appimage-glibc228/verify.sh [path/to/AppImage]
set -euo pipefail
# The script lives three levels below the repository root.
root="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$root"

glibc="$(ldd --version | sed -n '1s/.* \([0-9][0-9.]*\)$/\1/p')"
[[ "$(printf '%s\n2.28\n' "$glibc" | sort -V | tail -1)" == 2.28 ]] \
  || { echo "verification environment glibc $glibc is newer than 2.28" >&2; exit 1; }
if command -v gcc >/dev/null 2>&1; then
  echo "the verification environment has a compiler; it should be pristine" >&2
  exit 1
fi
. /etc/os-release
echo "verification environment: $NAME $VERSION_ID, glibc $glibc"

if [[ $# -ge 1 ]]; then
  images=("$1")
else
  shopt -s nullglob
  images=(target/x86_64-unknown-linux-gnu/release/bundle/appimage-glibc228/*.AppImage)
  shopt -u nullglob
fi
(( ${#images[@]} == 1 )) || { echo "expected one AppImage, found ${#images[@]}" >&2; exit 1; }
image="${images[0]}"

# The AppImage bundles every library it links except the core glibc set, and the libraries that
# are dlopened at runtime (wayland, xkbcommon, X11, fontconfig) load only when a window opens,
# so the version check below needs nothing beyond a bare system. If the build ever starts
# linking non-core libraries again, this check fails by design: a desktop system provides them,
# and the bundling policy should be revisited.
version="$(cat VERSION)"
printed="$(TMPDIR=/tmp "$image" --appimage-extract-and-run --version)"
[[ "$printed" == "winc $version" ]] \
  || { echo "winc --version printed '$printed', expected 'winc $version'" >&2; exit 1; }
echo "ok: ${image##*/} runs on $NAME $VERSION_ID (glibc $glibc), $printed"
