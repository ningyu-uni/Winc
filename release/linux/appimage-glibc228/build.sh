#!/usr/bin/env bash
# AppImage built against glibc 2.28, for systems older than the runner image (RHEL/Rocky/Alma 8,
# Debian 10). The whole build runs inside a glibc 2.28 container (AlmaLinux 8): linking records
# the symbol versions of the glibc it links against, so binaries linked here carry no version
# above GLIBC_2.28 and run on those systems and anything newer. The AppImage bundles the
# non-glibc libraries from the same environment (linuxdeploy), keeping the glibc floor.
#
# The script runs inside the container, with the repository mounted at any path. The host side
# is run.sh (local Docker) or the `Release · Linux x64 AppImage (glibc 2.28)` workflow (GitHub).
set -euo pipefail
# The script lives three levels below the repository root.
root="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$root"

# The build environment must be x86_64 and have glibc 2.28 or older; a newer glibc would leak
# its symbol versions into the binaries. AlmaLinux 8 is the reference environment (glibc 2.28
# exactly, the floor the packages promise).
[[ "$(uname -m)" == x86_64 ]] || { echo "needs an x86_64 environment: $(uname -m)" >&2; exit 1; }
glibc="$(ldd --version | sed -n '1s/.* \([0-9][0-9.]*\)$/\1/p')"
[[ "$(printf '%s\n2.28\n' "$glibc" | sort -V | tail -1)" == 2.28 ]] \
  || { echo "build environment glibc $glibc is newer than 2.28" >&2; exit 1; }
. /etc/os-release
echo "build environment: $NAME $VERSION_ID, glibc $glibc"

# System dependencies. patchelf lives in EPEL; libatomic is a runtime dependency of Node.
dnf install -y -q epel-release
dnf install -y -q gcc gcc-c++ make binutils git curl tar gzip xz patchelf squashfs-tools \
  pkgconf-pkg-config desktop-file-utils libatomic file

# Node runs the repository's release scripts (tool downloads with pinned SHA-256, version).
# Keep the version equal to the setup-node versions in the release workflows.
node_version=26.12.1
node_dir="/opt/node-v$node_version"
if ! [[ -x "$node_dir/bin/node" ]]; then
  mkdir -p "$node_dir"
  curl -fsSL "https://nodejs.org/dist/v$node_version/node-v$node_version-linux-x64.tar.xz" \
    | tar -xJ -C "$node_dir" --strip-components=1
fi
export PATH="$node_dir/bin:$PATH"

# Rust: rustup without a default toolchain, so the pinned rust-toolchain.toml decides. The
# toolchain file is the single source of truth; `rustup toolchain install` (no argument) reads it.
export PATH="$HOME/.cargo/bin:$PATH"
if ! command -v rustup >/dev/null 2>&1; then
  curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain none
fi
rustup toolchain install

target=x86_64-unknown-linux-gnu
release="target/$target/release"
bundle="$release/bundle"
export CARGO_INCREMENTAL=0
export CARGO_TERM_COLOR=always
cargo build --release --locked --target "$target" -p winc -p winc-pty
cargo xtask icons "$bundle/icons"
# The remote server ships for x86_64 only in this AppImage (the regular release also carries
# aarch64, which xtask builds together with it). It is a static musl binary with no C code,
# built with the linker bundled with Rust, and carries no glibc versions.
rustup target add x86_64-unknown-linux-musl
CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_LINKER=rust-lld \
  cargo build --release --locked -p winc-server --target x86_64-unknown-linux-musl
mkdir -p target/remote-server
cp "target/x86_64-unknown-linux-musl/release/winc-server" target/remote-server/winc-server-Linux-x86_64

# linuxdeploy, appimagetool and the type-2 runtime, pinned and checksummed by the repository
# script. They are AppImages themselves and run here with extraction instead of FUSE.
node release/linux/download-tools.mjs
tools="$root/target/release-tools"

version="$(node release/common/version.mjs)"
stem="Winc-$version-linux-x64-glibc228"
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
appdir="$workdir/winc.AppDir"
mkdir -p "$appdir/usr/bin" "$appdir/usr/share/applications" "$appdir/usr/share/icons/hicolor/256x256/apps"
install -m755 "$release/winc" "$release/winc-pty" "$appdir/usr/bin/"
install -m644 "$bundle/icons/winc.png" "$appdir/usr/share/icons/hicolor/256x256/apps/winc.png"
install -m644 release/linux/winc.desktop "$appdir/usr/share/applications/winc.desktop"
desktop-file-validate "$appdir/usr/share/applications/winc.desktop"

mkdir -p "$bundle/appimage-glibc228"
APPIMAGE_EXTRACT_AND_RUN=1 "$tools/linuxdeploy.AppImage" --appimage-extract-and-run \
  --appdir "$appdir" --executable "$appdir/usr/bin/winc" --executable "$appdir/usr/bin/winc-pty" \
  --desktop-file "$appdir/usr/share/applications/winc.desktop" \
  --icon-file "$appdir/usr/share/icons/hicolor/256x256/apps/winc.png" \
  --exclude-library 'libwayland-*' 2>&1 | tee "$workdir/linuxdeploy.log"
# Added after linuxdeploy: it would otherwise treat the static server as a library to patch.
install -Dm755 target/remote-server/winc-server-Linux-x86_64 -t "$appdir/usr/lib/winc"
rm -f "$appdir/AppRun"
install -m755 release/linux/AppRun "$appdir/AppRun"
# The architecture is named for appimagetool; it cannot reliably infer it from the AppDir.
ARCH=x86_64 APPIMAGE_EXTRACT_AND_RUN=1 "$tools/appimagetool.AppImage" --appimage-extract-and-run \
  --runtime-file "$tools/runtime" "$appdir" "$bundle/appimage-glibc228/$stem.AppImage"
image="$root/$bundle/appimage-glibc228/$stem.AppImage"
(cd "$(dirname "$image")" && sha256sum "$(basename "$image")" > "$(basename "$image").sha256")

# Audit the glibc symbol versions of every binary and bundled library. Any version above 2.28
# would break the systems this AppImage promises, so it fails the build naming the offender.
echo "glibc symbol audit:"
symbols="$(find "$appdir" -type f \( -name winc -o -name winc-pty -o -name '*.so*' \) -print0 \
  | xargs -0 -r objdump -T 2>/dev/null | grep -o 'GLIBC_[0-9][0-9.]*' | sort -Vu || true)"
[[ -n "$symbols" ]] || { echo "the audit found no glibc references, which cannot be right" >&2; exit 1; }
find "$appdir" -type f \( -name winc -o -name winc-pty -o -name '*.so*' \) | sort | while read -r file; do
  highest="$(objdump -T "$file" 2>/dev/null | grep -o 'GLIBC_[0-9][0-9.]*' | sort -Vu | tail -1 || true)"
  echo "  ${file#"$appdir"}: ${highest:--}"
done
highest="${symbols##*$'\n'}"; highest="${highest#GLIBC_}"
if [[ "$(printf '%s\n2.28\n' "$highest" | sort -V | tail -1)" != 2.28 ]]; then
  echo "a binary or library references glibc symbols above 2.28:" >&2
  printf '%s\n' "$symbols" >&2
  exit 1
fi

# The AppImage must be self-sufficient apart from the host's glibc and the libraries that are
# dlopened at runtime (xkbcommon, X11, fontconfig) plus the linked libwayland-client, which the
# exclusion keeps uninstalled: a desktop system provides them all. Extract and run to prove it
# works on this very glibc 2.28 environment.
extract="$workdir/extract"
mkdir "$extract"
(cd "$extract" && "$image" --appimage-extract >/dev/null)
test -x "$extract/squashfs-root/usr/bin/winc"
test -f "$extract/squashfs-root/usr/lib/winc/winc-server-Linux-x86_64"
if find "$extract/squashfs-root/usr/lib" -name 'libwayland*' -print -quit | grep -q .; then
  echo "AppImage still bundles Wayland libraries" >&2
  exit 1
fi
printed="$("$extract/squashfs-root/AppRun" --version)"
[[ "$printed" == "winc $version" ]] || { echo "winc --version printed '$printed', expected 'winc $version'" >&2; exit 1; }
(cd "$workdir" && "$image" --appimage-extract-and-run --version) | grep -Fx "winc $version" \
  || { echo "the packed AppImage did not report 'winc $version'" >&2; exit 1; }

echo "ok: $stem runs on glibc 2.28 (winc $version)"
echo "sha256: $(cut -d' ' -f1 "$image.sha256")"
