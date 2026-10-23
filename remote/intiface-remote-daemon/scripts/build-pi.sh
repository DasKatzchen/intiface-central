#!/usr/bin/env bash
# Cross-compile intiface-remote-daemon for 64-bit Raspberry Pi OS from an
# x86_64 Linux host. Needs: rustup, uv, git, make.
#
#   ./scripts/build-pi.sh            -> target/aarch64-unknown-linux-gnu/release/
#
# Uses zig (via cargo-zigbuild) as the cross linker, libdbus built from
# source (vendored), and libudev-zero for link-time libudev symbols. At
# runtime the Pi's own libudev.so.1 is used. glibc floor: 2.31 (Bullseye+).
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
work="${WORK_DIR:-$here/target/pi-toolchain}"
mkdir -p "$work"

rustup target add aarch64-unknown-linux-gnu

if [ ! -x "$work/venv/bin/cargo-zigbuild" ]; then
  uv venv -q "$work/venv"
  uv pip install -q --python "$work/venv" ziglang cargo-zigbuild
fi
export PATH="$work/venv/bin:$PATH"

cat > "$work/zigcc" <<EOF
#!/bin/sh
exec "$work/venv/bin/python" -m ziglang cc -target aarch64-linux-gnu.2.31 "\$@"
EOF
chmod +x "$work/zigcc"

sysroot="$work/sysroot"
if [ ! -f "$sysroot/lib/libudev.so" ]; then
  rm -rf "$work/libudev-zero"
  git clone -q --depth 1 https://github.com/illiliti/libudev-zero.git "$work/libudev-zero"
  make -s -C "$work/libudev-zero" CC="$work/zigcc" \
    AR="$work/venv/bin/python -m ziglang ar" PREFIX="$sysroot" install
fi

export PKG_CONFIG_ALLOW_CROSS=1
export PKG_CONFIG_PATH="$sysroot/lib/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR=/
export CFLAGS_aarch64_unknown_linux_gnu="-I$sysroot/include"
export RUSTFLAGS="${RUSTFLAGS:-} -L$sysroot/lib"

cd "$here"
cargo zigbuild --release --target aarch64-unknown-linux-gnu.2.31
echo "Built: $here/target/aarch64-unknown-linux-gnu/release/intiface-remote-daemon"
