// NAPI surface over libverge_ohos_bridge.so (Rust P1 backend).
// The bridge (and the mihomo core binary) are packaged as
// entry/libs/arm64/lib*.so and resolved at runtime via dlopen — the same
// model FlClash-HarmonyOS uses for its core.
#include "napi/native_api.h"
#include <dlfcn.h>
#include <hilog/log.h>
#include <string>

// --- resolved symbol types (mirror the Rust C ABI) ---
extern "C" {
typedef int (*fn_ping)(void);
typedef const char *(*fn_version)(void);
typedef int (*fn_config_generate)(const char *, const char *);
typedef int (*fn_core_start)(const char *, const char *, const char *, long long *);
typedef int (*fn_core_stop)(void);
typedef int (*fn_core_status)(void);
typedef int (*fn_core_wait_ready)(unsigned long long);
typedef long long (*fn_core_rest_get)(const char *, char *, unsigned long);
typedef long long (*fn_subscription_fetch)(const char *, const char *);
typedef const char *(*fn_last_error)(void);
// In-process mihomo (HarmonyOS denies execve on app files, so the core is a
// c-shared library loaded here instead of a sidecar child process).
typedef int (*fn_core_start_embedded)(const char *, const char *);
typedef int (*fn_core_stop_embedded)(void);
typedef int (*fn_core_is_running_embedded)(void);
}

static void *g_bridge = nullptr;
static fn_ping g_ping = nullptr;
static fn_version g_version = nullptr;
static fn_config_generate g_config_generate = nullptr;
static fn_core_start g_core_start = nullptr;
static fn_core_stop g_core_stop = nullptr;
static fn_core_status g_core_status = nullptr;
static fn_core_wait_ready g_core_wait_ready = nullptr;
static fn_core_rest_get g_core_rest_get = nullptr;
static fn_subscription_fetch g_subscription_fetch = nullptr;
static fn_last_error g_last_error = nullptr;

static void *g_core = nullptr;
static fn_core_start_embedded g_core_start_embedded = nullptr;
static fn_core_stop_embedded g_core_stop_embedded = nullptr;
static fn_core_is_running_embedded g_core_is_running_embedded = nullptr;

// libverge_mihomo.so is the mihomo Go core built with -buildmode=c-shared
// (see native/ohos-core/main.go). It ships in libs/arm64 and is resolved by
// soname.
static bool ensure_core() {
  if (g_core && g_core_start_embedded && g_core_stop_embedded &&
      g_core_is_running_embedded) {
    return true;
  }
  if (g_core) {
    dlclose(g_core);
    g_core = nullptr;
    g_core_start_embedded = nullptr;
    g_core_stop_embedded = nullptr;
    g_core_is_running_embedded = nullptr;
  }
  g_core = dlopen("libverge_mihomo.so", RTLD_NOW | RTLD_LOCAL);
  if (!g_core)
    return false;
  g_core_start_embedded =
      (fn_core_start_embedded)dlsym(g_core, "verge_core_start_embedded");
  g_core_stop_embedded =
      (fn_core_stop_embedded)dlsym(g_core, "verge_core_stop_embedded");
  g_core_is_running_embedded =
      (fn_core_is_running_embedded)dlsym(g_core, "verge_core_is_running_embedded");
  if (!g_core_start_embedded || !g_core_stop_embedded ||
      !g_core_is_running_embedded) {
    dlclose(g_core);
    g_core = nullptr;
    return false;
  }
  return true;
}

static bool bridge_ready() {
  return g_ping && g_version && g_config_generate && g_core_start &&
         g_core_stop && g_core_status && g_core_wait_ready &&
         g_core_rest_get && g_subscription_fetch && g_last_error;
}

static bool ensure_bridge() {
  if (g_bridge && bridge_ready()) return true;
  // Re-resolve from scratch on any previous partial/failed init (a missing
  // symbol must NOT leave a half-initialized handle that later short-circuits
  // into a NULL call).
  if (g_bridge) {
    dlclose(g_bridge);
    g_bridge = nullptr;
    g_ping = nullptr;
    g_version = nullptr;
    g_config_generate = nullptr;
    g_core_start = nullptr;
    g_core_stop = nullptr;
    g_core_status = nullptr;
    g_core_wait_ready = nullptr;
    g_core_rest_get = nullptr;
    g_subscription_fetch = nullptr;
  g_last_error = nullptr;
  }
  g_bridge = dlopen("libverge_ohos_bridge.so", RTLD_NOW | RTLD_GLOBAL);
  if (!g_bridge)
    return false;
  g_ping = (fn_ping)dlsym(g_bridge, "verge_ohos_ping");
  g_version = (fn_version)dlsym(g_bridge, "verge_ohos_version");
  g_config_generate = (fn_config_generate)dlsym(g_bridge, "verge_config_generate");
  g_core_start = (fn_core_start)dlsym(g_bridge, "verge_core_start");
  g_core_stop = (fn_core_stop)dlsym(g_bridge, "verge_core_stop");
  g_core_status = (fn_core_status)dlsym(g_bridge, "verge_core_status");
  g_core_wait_ready = (fn_core_wait_ready)dlsym(g_bridge, "verge_core_wait_ready");
  g_core_rest_get = (fn_core_rest_get)dlsym(g_bridge, "verge_core_rest_get");
  g_subscription_fetch =
      (fn_subscription_fetch)dlsym(g_bridge, "verge_subscription_fetch");
  g_last_error =
      (fn_last_error)dlsym(g_bridge, "verge_last_error");
  if (!bridge_ready()) {
    // A missing symbol: drop the handle so the next call retries cleanly
    // instead of short-circuiting into a NULL function call.
    dlclose(g_bridge);
    g_bridge = nullptr;
    return false;
  }
  return true;
}

static napi_value JsPing(napi_env env, napi_callback_info) {
  napi_value out;
  napi_create_int32(env, ensure_bridge() ? g_ping() : -1, &out);
  return out;
}

static napi_value JsBridgeVersion(napi_env env, napi_callback_info) {
  napi_value out;
  napi_create_string_utf8(env, ensure_bridge() ? g_version() : "bridge not loadable",
                          NAPI_AUTO_LENGTH, &out);
  return out;
}

static std::string GetStringArg(napi_env env, size_t argc, napi_value *argv,
                                size_t index, const char *fallback = "") {
  if (index >= argc)
    return fallback;
  napi_valuetype type;
  napi_typeof(env, argv[index], &type);
  if (type != napi_string)
    return fallback;
  size_t len = 0;
  napi_get_value_string_utf8(env, argv[index], nullptr, 0, &len);
  std::string value(len + 1, '\0');
  napi_get_value_string_utf8(env, argv[index], &value[0], len + 1, &len);
  value.resize(len);
  return value;
}

static napi_value JsConfigGenerate(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value argv[2];
  napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
  std::string profile = GetStringArg(env, argc, argv, 0);
  std::string runtime = GetStringArg(env, argc, argv, 1);
  napi_value out;
  napi_create_int32(
      env, ensure_bridge() ? g_config_generate(profile.c_str(), runtime.c_str()) : -1,
      &out);
  return out;
}

static napi_value JsCoreStart(napi_env env, napi_callback_info info) {
  size_t argc = 3;
  napi_value argv[3];
  napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
  std::string bin = GetStringArg(env, argc, argv, 0);
  std::string dir = GetStringArg(env, argc, argv, 1);
  std::string cfg = GetStringArg(env, argc, argv, 2);
  long long pid = -1;
  int rc = ensure_bridge()
               ? g_core_start(bin.c_str(), dir.c_str(), cfg.c_str(), &pid)
               : -1;
  napi_value out;
  napi_create_int64(env, rc == 0 ? pid : rc, &out);
  return out;
}

static napi_value JsCoreStop(napi_env env, napi_callback_info) {
  napi_value out;
  napi_create_int32(env, ensure_bridge() ? g_core_stop() : -1, &out);
  return out;
}

static napi_value JsCoreStatus(napi_env env, napi_callback_info) {
  napi_value out;
  napi_create_int32(env, ensure_bridge() ? g_core_status() : -1, &out);
  return out;
}

static napi_value JsCoreWaitReady(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value argv[1];
  napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
  double ms = 5000;
  napi_valuetype type;
  if (argc >= 1 && napi_typeof(env, argv[0], &type) == napi_ok &&
      type == napi_number) {
    napi_get_value_double(env, argv[0], &ms);
  }
  napi_value out;
  napi_create_int32(env,
                    ensure_bridge() ? g_core_wait_ready((unsigned long long)ms) : -1,
                    &out);
  return out;
}

static napi_value JsCoreRestGet(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value argv[1];
  napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
  std::string path = GetStringArg(env, argc, argv, 0, "/version");
  std::string body;
  if (ensure_bridge()) {
    long long need = g_core_rest_get(path.c_str(), nullptr, 0);
    if (need > 0) {
      body.resize((size_t)need);
      g_core_rest_get(path.c_str(), &body[0], (unsigned long)need);
      body.resize(need - 1 > 0 ? (size_t)(need - 1) : 0);
    }
  }
  napi_value out;
  napi_create_string_utf8(env, body.c_str(), body.size(), &out);
  return out;
}

static napi_value JsSubscriptionFetch(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value argv[2];
  napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
  std::string url = GetStringArg(env, argc, argv, 0);
  std::string outPath = GetStringArg(env, argc, argv, 1);
  napi_value out;
  napi_create_int64(
      env,
      ensure_bridge() ? g_subscription_fetch(url.c_str(), outPath.c_str()) : -1,
      &out);
  return out;
}

static napi_value JsCoreStartEmbedded(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value argv[2];
  napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
  std::string cfg = GetStringArg(env, argc, argv, 0);
  std::string home = GetStringArg(env, argc, argv, 1);
  napi_value out;
  int rc = -2; // library load failure
  if (ensure_core()) {
    rc = g_core_start_embedded(cfg.c_str(), home.c_str());
  } else {
    const char *dl = dlerror();
    OH_LOG_Print(LOG_APP, LOG_ERROR, 0x0666, "VergeNAPI",
                 "libverge_mihomo.so load failed: %{public}s",
                 dl ? dl : "(no dlerror)");
  }
  napi_create_int32(env, rc, &out);
  return out;
}

static napi_value JsCoreStopEmbedded(napi_env env, napi_callback_info) {
  napi_value out;
  napi_create_int32(env, ensure_core() ? g_core_stop_embedded() : -1, &out);
  return out;
}

static napi_value JsCoreIsRunningEmbedded(napi_env env, napi_callback_info) {
  napi_value out;
  napi_create_int32(env,
                    ensure_core() ? g_core_is_running_embedded() : 0, &out);
  return out;
}

static napi_value JsLastError(napi_env env, napi_callback_info) {
  // Distinguish a real operation error from "the bridge itself is missing".
  // The old code collapsed both into "bridge not loadable", which hid the
  // actual subscription failure from the UI.
  napi_value out;
  if (g_bridge && g_last_error) {
    napi_create_string_utf8(env, g_last_error(), NAPI_AUTO_LENGTH, &out);
    return out;
  }
  const char *dl = dlerror();
  napi_create_string_utf8(env,
                          dl ? dl : "bridge not loadable (dlopen/dlsym failed)",
                          NAPI_AUTO_LENGTH, &out);
  return out;
}

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports) {
  napi_property_descriptor desc[] = {
      {"ping", nullptr, JsPing, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"bridgeVersion", nullptr, JsBridgeVersion, nullptr, nullptr, nullptr,
       napi_default, nullptr},
      {"configGenerate", nullptr, JsConfigGenerate, nullptr, nullptr, nullptr,
       napi_default, nullptr},
      {"coreStart", nullptr, JsCoreStart, nullptr, nullptr, nullptr,
       napi_default, nullptr},
      {"coreStop", nullptr, JsCoreStop, nullptr, nullptr, nullptr,
       napi_default, nullptr},
      {"coreStatus", nullptr, JsCoreStatus, nullptr, nullptr, nullptr,
       napi_default, nullptr},
      {"coreWaitReady", nullptr, JsCoreWaitReady, nullptr, nullptr, nullptr,
       napi_default, nullptr},
      {"coreRestGet", nullptr, JsCoreRestGet, nullptr, nullptr, nullptr,
       napi_default, nullptr},
      {"subscriptionFetch", nullptr, JsSubscriptionFetch, nullptr, nullptr,
       nullptr, napi_default, nullptr},
      {"lastError", nullptr, JsLastError, nullptr, nullptr, nullptr,
       napi_default, nullptr},
      {"coreStartEmbedded", nullptr, JsCoreStartEmbedded, nullptr, nullptr,
       nullptr, napi_default, nullptr},
      {"coreStopEmbedded", nullptr, JsCoreStopEmbedded, nullptr, nullptr,
       nullptr, napi_default, nullptr},
      {"coreIsRunningEmbedded", nullptr, JsCoreIsRunningEmbedded, nullptr,
       nullptr, nullptr, napi_default, nullptr},
  };
  napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
  return exports;
}
EXTERN_C_END

static napi_module vergeModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "entry",
    .nm_priv = nullptr,
};

extern "C" __attribute__((constructor)) void RegisterVergeModule(void) {
  napi_module_register(&vergeModule);
}
