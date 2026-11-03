#!/usr/bin/env bash
# Build the mihomo core as an in-process shared library for HarmonyOS.
#
# HarmonyOS denies execve() on app-owned files (EACCES even at mode 0755,
# SELinux label debug_hap_data_file), so the desktop sidecar model cannot
# work. The supported pattern — used by FlClash-HarmonyOS — is a c-shared
# library dlopen'ed by the app (libverge_mihomo.so, entry
# verge_core_start_embedded in native/ohos-core/main.go).
#
# Prerequisite: scripts/build-core.sh has already prepared the patched Go
# toolchain and the mihomo clone.
#
# Usage: scripts/build-core-embedded.sh [mihomo version tag]  (default v1.19.33)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-v1.19.33}"
TOOLCHAIN="$ROOT/toolchain/go-nonglibc"
CORE_SRC="$ROOT/core/mihomo"
DEVECO="/Applications/DevEco-Studio.app/Contents"
NDK="$DEVECO/sdk/default/openharmony/native"
OUT="$ROOT/out/libverge_mihomo-ohos-arm64.so"

if [ ! -x "$TOOLCHAIN/bin/go" ] || [ ! -d "$CORE_SRC/.git" ]; then
  echo ">> toolchain or mihomo clone missing; run scripts/build-core.sh first" >&2
  exit 1
fi

mkdir -p "$CORE_SRC/cmd/verge-ohos" "$ROOT/out"
cp "$ROOT/native/ohos-core/main.go" "$CORE_SRC/cmd/verge-ohos/main.go"

cd "$CORE_SRC"
env \
  GOROOT="$TOOLCHAIN" \
  PATH="$TOOLCHAIN/bin:$PATH" \
  GOTOOLCHAIN=local \
  GOPROXY="https://goproxy.cn,direct" \
  GOOS=linux GOARCH=arm64 CGO_ENABLED=1 \
  CC="$ROOT/scripts/ohos-aarch64-clang.sh" \
  CXX="$NDK/llvm/bin/clang++" \
  AR="$ROOT/scripts/ohos-llvm-ar.sh" \
  CGO_LDFLAGS="-Wl,-z,max-page-size=16384" \
  go build -tags with_gvisor -buildmode=c-shared -trimpath \
  -ldflags "-s -w -X github.com/metacubex/mihomo/constant.Version=$VERSION-ohos" \
  -o "$OUT" ./cmd/verge-ohos

echo ">> embedded core built: $OUT"
"$NDK/llvm/bin/llvm-readelf" -d "$OUT" | grep NEEDED || true
