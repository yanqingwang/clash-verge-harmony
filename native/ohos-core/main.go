// In-process mihomo entry for HarmonyOS (copied into the mihomo clone as
// cmd/verge-ohos/main.go by scripts/build-core.sh --embedded).
//
// HarmonyOS denies execve() on app-owned files, so the desktop sidecar model
// (spawn the core binary) cannot work. The supported alternative — the one
// FlClash-HarmonyOS ships — is to link the core into the app as a shared
// library and drive it from the app process. This file exposes the smallest
// API that does that: start from a runtime config, stop, and report status.
//
// Built with:
//   CGO_ENABLED=1 GOOS=linux GOARCH=arm64 \
//   CC=scripts/ohos-aarch64-clang.sh \
//   go build -tags "with_gvisor" -buildmode=c-shared \
//     -o out/libverge_mihomo.so ./cmd/verge-ohos
package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"sync"

	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/hub"
	"github.com/metacubex/mihomo/hub/executor"
	"github.com/metacubex/mihomo/log"
)

var (
	coreMu      sync.Mutex
	coreRunning bool
)

// verge_core_start_embedded starts mihomo from homeDir/configPath.
// Returns 0 on success, -1 for a home-dir init failure, -2 for a config
// parse/listener failure.
//
//export verge_core_start_embedded
func verge_core_start_embedded(configPath *C.char, homeDir *C.char) C.int {
	cfg := C.GoString(configPath)
	home := C.GoString(homeDir)

	coreMu.Lock()
	defer coreMu.Unlock()
	if coreRunning {
		return 0
	}

	constant.SetHomeDir(home)
	constant.SetConfig(cfg)
	if err := config.Init(home); err != nil {
		log.Errorln("verge ohos: config.Init(%s): %s", home, err.Error())
		return -1
	}
	if err := hub.Parse(nil); err != nil {
		log.Errorln("verge ohos: hub.Parse(%s): %s", cfg, err.Error())
		return -2
	}
	coreRunning = true
	log.Infoln("verge ohos: core started from %s", cfg)
	return 0
}

// verge_core_stop_embedded tears the in-process listeners down.
//
//export verge_core_stop_embedded
func verge_core_stop_embedded() C.int {
	coreMu.Lock()
	defer coreMu.Unlock()
	if !coreRunning {
		return 0
	}
	executor.Shutdown()
	coreRunning = false
	log.Infoln("verge ohos: core stopped")
	return 0
}

// verge_core_is_running_embedded reports 1 while the in-process core is up.
//
//export verge_core_is_running_embedded
func verge_core_is_running_embedded() C.int {
	coreMu.Lock()
	defer coreMu.Unlock()
	if coreRunning {
		return 1
	}
	return 0
}

func main() {}
