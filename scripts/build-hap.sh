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
hvigorw --mode module -p product=default -p module=entry@default assembleHap --no-daemon "$@"

ls -lh entry/build/default/outputs/default/*.hap
