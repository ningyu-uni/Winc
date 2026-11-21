# AppImage for glibc 2.28

The regular Linux release builds on Ubuntu 24.04 (glibc 2.39); its AppImage runs only on
systems with glibc 2.39 or newer. This pipeline adds a standalone AppImage that runs on
**glibc 2.28 and newer** — RHEL/Rocky/AlmaLinux 8, Debian 10 and their derivatives.

## How it works

Linking records the glibc symbol versions of the glibc it links against, so the binaries must
be linked inside a glibc 2.28 environment. The whole build therefore runs in an
`almalinux:8.10` container (glibc 2.28 exactly):

1. `build.sh` runs inside the container: system dependencies, the pinned Rust toolchain
   (`rust-toolchain.toml`), `cargo build --release`, the icons and the x86_64 remote server,
   then
   linuxdeploy/appimagetool pack the AppImage with the libraries from the same environment
   (`Winc-<version>-linux-x64-glibc228.AppImage` plus its SHA-256 file).
2. Every binary and bundled library is audited: no glibc symbol version above 2.28 is allowed.
3. The AppImage is extracted and run right there (`winc --version`), inside glibc 2.28.
4. `verify.sh` runs in a **fresh, pristine** container with no build tooling and runs the
   packed AppImage — proof it works on a bare glibc 2.28 system.

## Run it

On GitHub (preferred): the workflow **Release · Linux x64 AppImage (glibc 2.28)**
(`.github/workflows/release-linux-appimage-glibc228.yml`) runs both container steps and
uploads the AppImage and its checksum as the artifact
`release-assets-linux-x64-appimage-glibc228`. Start it from the Actions tab (workflow_dispatch).

Locally, with Docker (on Apple Silicon the x86_64 container runs under emulation, slower than
CI):

```sh
bash release/linux/appimage-glibc228/run.sh
```

## Runtime requirements of the AppImage

The AppImage bundles the libraries it links (from the AlmaLinux 8 environment) except the core
glibc set and, by policy (as in the regular release), `libwayland-client` — and the libraries
that are dlopened at runtime (`libxkbcommon`, X11 client libraries, fontconfig files) load from
the host. A desktop system with glibc ≥ 2.28 provides all of them.

## Wiring into the release

The regular release pipeline is untouched. To publish this AppImage with a release, give the
workflow a `workflow_call` trigger, call it from `release.yml` next to `linux-x64`, and add the
asset to `releaseAssets` in `release/common/collect-assets.mjs`.
