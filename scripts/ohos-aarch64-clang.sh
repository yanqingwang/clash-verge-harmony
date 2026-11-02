#!/bin/sh
exec "/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/native/llvm/bin/clang" \
  --target=aarch64-unknown-linux-ohos \
  --sysroot="/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/native/sysroot" \
  "$@"
