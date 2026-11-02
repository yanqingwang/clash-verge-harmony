#!/usr/bin/env bash
# Build the HarmonyOS HAP (ArkWeb shell) with the DevEco Studio 26 toolchain.
# Produces an UNSIGNED hap; signing needs a provisioning profile registered for
# the app's bundleName (Huawei signing server requires a mainland-IP connection).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEVECO="/Applications/DevEco-Studio.app/Contents"

export PATH="$DEVECO/tools/node/bin:$DEVECO/tools/ohpm/bin:$DEVECO/tools/hvigor/bin:$PATH"
export JAVA_HOME="$DEVECO/jbr/Contents/Home"
export DEVECO_SDK_HOME="$DEVECO/sdk"

cd "$ROOT/app"
[ -f oh-package-lock.json5 ] || ohpm install

# stage prebuilt native libs (must be named lib*.so for HAP extraction)
mkdir -p entry/libs/arm64 entry/libs/arm64-v8a
cp "$ROOT/out/verge-mihomo-ohos-arm64" entry/libs/arm64/libverge_mihomo.so
cp "$ROOT/native-rs/verge-ohos-bridge/target/aarch64-unknown-linux-ohos/release/libverge_ohos_bridge.so" \
   entry/libs/arm64/libverge_ohos_bridge.so
cp entry/libs/arm64/libverge_mihomo.so entry/libs/arm64/libverge_ohos_bridge.so entry/libs/arm64-v8a/

hvigorw --mode module -p product=default -p module=entry@default assembleHap --no-daemon "$@"

ls -lh entry/build/default/outputs/default/*.hap
