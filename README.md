# clash-verge-harmony

Clash Verge Rev (v2.5.8) → HarmonyOS 7（鸿蒙7 / API 26 / "26.0.0"）移植工程。
研究结论与完整分析见 `wk/AIReports/clash-verge-鸿蒙7移植可行性报告-2026-11-02.md`。

## P0 spike 结果（2026-11-02，全部在本机验证）

| 项 | 结果 | 证据 |
|---|---|---|
| ① mihomo 交叉编译 | ✅ | 补丁工具链 `jgowdy/go@1a087d05`（go1.27-devel）+ `GOOS=linux GOARCH=arm64 CGO_ENABLED=0 -tags with_gvisor` → `out/verge-mihomo-ohos-arm64`：**ELF 64-bit aarch64，静态链接，无 INTERP/NEEDED，LOAD align 0x10000**（满足 16KB 页设备）。进程模型与桌面版 Verge 一致（sidecar 可执行文件，无需 c-shared） |
| ② Rust cdylib | ✅ | `native-rs/verge-ohos-bridge` → `libverge_ohos_bridge.so`：aarch64，仅 `NEEDED libc.so`（OHOS musl），导出 `verge_ohos_ping/verge_ohos_version` C ABI（NAPI 可直接调用）。rustc 1.99.1 `aarch64-unknown-linux-ohos`（官方 Tier 2）+ NDK clang 15.0.4 wrapper |
| ③ ArkWeb 壳 HAP | ✅ | `app/`（bundleName `io.github.clashverge.harmony`，runtimeOS HarmonyOS，compatible/targetSdk "26.0.0"）→ hvigorw 6.26.8 构建成功 → `entry-default-unsigned.hap`（含 ArkTS 字节码 + ArkWeb 测试页 + ohosBridge JS 桥） |

## P1 结果（2026-11-02）

| 项 | 结果 | 证据 |
|---|---|---|
| 后端逻辑移植（Rust） | ✅ | `native-rs/verge-ohos-bridge/src/{config,core,subscription}.rs`：配置生成（镜像 `src-tauri/src/config/clash.rs` 语义：模板填充 + profile 覆盖 + secret 兜底）、核心 sidecar 管理（spawn `-d/-f`、REST `/version` 健康检查、stop）、订阅拉取（rustls，无 OpenSSL） |
| 宿主机端到端 | ✅ | 补丁工具链同源构建 darwin mihomo → 集成测试 `core_lifecycle_end_to_end`：生成配置 → spawn → `/version` → 带鉴权 `GET /proxies` → stop → status 归零（0.78s，6 测试全绿） |
| OHOS 交叉编译 | ✅ | 7 个 C ABI 符号导出、仅依赖 `libc.so`；`ring` 需要 `CC_aarch64_unknown_linux_ohos`（已写入 `.cargo/config.toml [env]`） |
| HAP 集成 | ✅ | `libverge_mihomo.so`（核心可执行）+ `libverge_ohos_bridge.so` 打入 `libs/{arm64,arm64-v8a}`；NAPI 模块 `libentry.so` dlopen 桥接（9 个方法）；`Index.ets` 实时显示 bridge 状态。HAP 114MB |

**尚未验证（需设备/模拟器或签名 profile）**：HAP 安装与 ohosBridge 页面在真机/模拟器上运行；mihomo 在 OHOS 运行时的 syscall 行为；VpnExtensionAbility TUN 数据面。

## 构建

```bash
scripts/build-core.sh            # mihomo → out/verge-mihomo-ohos-arm64
scripts/build-hap.sh             # staging + app/ → entry-default-unsigned.hap
```

### 用 DevEco Studio 打开（推荐日常路径）

1. DevEco Studio → **Open** → 选择 `code/clash-verge-harmony/app`（注意：是 `app` 子目录，不是仓库根）。
2. 首次打开若提示生成 hvigor wrapper / sync，确认即可（本地已缓存 hvigor 6.26.8 与 ohpm 依赖，离线可用）。
3. `Build → Build Hap(s)/APP(s) → Build Hap(s)` 即可复现 CLI 同款产物；native 库由 `scripts/build-hap.sh` 同源的 staging 步骤保证（改 Rust 后先跑一次该脚本再回 IDE，或 IDE 内直接 Build——libs 已在 `entry/libs/` 就位）。
4. 自动签名：**File → Project Structure → Signing Configs → 勾选 Automatically generate signature**（需已实名华为账号；签名服务器要求大陆网络）。签名成功后 `Run` 直接推到模拟器/真机。
5. 运行验证点：首屏顶部绿色状态条显示 `bridge=… ping=42 coreStatus=…`；下方 ArkWeb 测试页显示 `ohosBridge.ping()` 结果。

前置：DevEco Studio 26.0.0.851（含 SDK API 26 / NDK / hvigor 6.26.8 / JBR）。
签名：需为 `io.github.clashverge.harmony` 注册调试 profile（华为签名服务器要求大陆网络）；本机 `~/.ohos/config` 现有 profile 绑定的是 `com.heartroad.cardcounter`，不可复用。

## 工程结构

```
scripts/          build-core.sh / build-hap.sh / gen_icons.py
toolchain/        bootstrap Go + jgowdy/go 补丁工具链（构建产物，不入库）
core/mihomo/      mihomo 源码（浅克隆 @ v1.19.33，不入库）
native-rs/verge-ohos-bridge/   Rust→OHOS 桥（P0 验证件；P1 挂入 src-tauri 移植逻辑）
app/              ArkWeb 壳工程（Stage 模型，API 26）
out/              构建产物
```

## 路线图（方案 B，见报告第 6 节）

- **P1**：Rust 后端去桌面化移植进 `verge-ohos-bridge`（配置生成/订阅/核心管理），mihomo 以 HAP 内 `libs/arm64` 打包 + 运行时解包执行（`maxChildProcess: 8` 已声明）。
- **P2**：ArkWeb 加载 Verge React 构建产物，`contract.ts` 层 shim `invoke/listen` → ArkTS/JSBridge。
- **P3**：VpnExtensionAbility（TUN→mihomo）+ 长时任务保活；分应用代理受 `CONNECTIVITY_INTERNAL` 系统权限限制（平台约束，明确降级）。
- **P4**：注册 profile → 签名 → 真机（DevEco Testing 云真机可先行）。

上游参照：`code/clash-verge-rev`（v2.5.8）；先例：[ClashBox](https://github.com/xiaobaigroup/ClashBox)、[FlClash-HarmonyOS](https://github.com/shenyingjun5/FlClash-HarmonyOS)。
