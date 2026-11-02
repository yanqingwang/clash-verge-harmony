#!/usr/bin/env bash
# Build the mihomo core for HarmonyOS (ohos/arm64) using the patched Go toolchain.
#
# Recipe proven by FlClash-HarmonyOS (scripts/ohos/prepare_go_toolchain.sh) and
# ClashBox CI: GOOS=linux GOARCH=arm64 CGO_ENABLED=0 with the non-glibc Go fork
# jgowdy/go @ 1a087d05 — produces a fully static aarch64 ELF that runs on
# HarmonyOS NEXT/7 (64KB LOAD alignment satisfies 16KB-page devices).
#
# Usage: scripts/build-core.sh [mihomo version tag]   (default v1.19.33)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-v1.19.33}"
FORK_REF="1a087d05b5cf9573876b18812d8d5516f16bbe57"
NDK_CLANG="/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/native/llvm/bin/clang"

TOOLCHAIN="$ROOT/toolchain/go-nonglibc"
BOOTSTRAP="$ROOT/toolchain/bootstrap"
CORE_SRC="$ROOT/core/mihomo"

# 1. bootstrap Go (host) to build the fork
if [ ! -x "$BOOTSTRAP/bin/go" ]; then
  echo ">> downloading bootstrap Go (darwin/arm64)"
  mkdir -p "$BOOTSTRAP"
  URL=$(curl -s "https://go.dev/dl/?mode=json" | python3 -c "
import json,sys
rel=json.load(sys.stdin)[0]
print(next(f['filename'] for f in rel['files'] if f['os']=='darwin' and f['arch']=='arm64' and f['kind']=='archive'))")
  curl -sL -o /tmp/go-bootstrap.tar.gz "https://go.dev/dl/$URL"
  tar -xzf /tmp/go-bootstrap.tar.gz -C "$BOOTSTRAP" --strip-components=1
fi

# 2. patched Go fork
if [ ! -x "$TOOLCHAIN/bin/go" ]; then
  echo ">> cloning Go fork jgowdy/go @ $FORK_REF"
  git init -q "$TOOLCHAIN"
  git -C "$TOOLCHAIN" remote add origin git@github.com:jgowdy/go.git
  git -C "$TOOLCHAIN" fetch --depth 1 origin "$FORK_REF"
  git -C "$TOOLCHAIN" checkout -q FETCH_HEAD
  echo ">> building toolchain (2-5 min)"
  (cd "$TOOLCHAIN/src" && GOTOOLCHAIN=local GOROOT_BOOTSTRAP="$BOOTSTRAP" ./make.bash >/dev/null)
fi
"$TOOLCHAIN/bin/go" version

# 3. mihomo source
if [ ! -d "$CORE_SRC/.git" ]; then
  echo ">> cloning mihomo $VERSION"
  git init -q "$CORE_SRC"
  git -C "$CORE_SRC" remote add origin git@github.com:MetaCubeX/mihomo.git
  git -C "$CORE_SRC" fetch --depth 1 origin tag "$VERSION"
  git -C "$CORE_SRC" checkout -q FETCH_HEAD
fi

# 4. cross-compile (sidecar executable model — same process model as desktop Verge)
mkdir -p "$ROOT/out"
cd "$CORE_SRC"
env \
  GOROOT="$TOOLCHAIN" \
  PATH="$TOOLCHAIN/bin:$PATH" \
  GOTOOLCHAIN=local \
  GOPROXY="https://goproxy.cn,direct" \
  GOOS=linux GOARCH=arm64 CGO_ENABLED=0 \
  go build -tags with_gvisor -trimpath \
  -ldflags "-s -w -X github.com/metacubex/mihomo/constant.Version=$VERSION-ohos" \
  -o "$ROOT/out/verge-mihomo-ohos-arm64" .

# 5. verify
file "$ROOT/out/verge-mihomo-ohos-arm64"
"$NDK_CLANG" --version >/dev/null 2>&1 || true
echo ">> core built: $ROOT/out/verge-mihomo-ohos-arm64"
