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

## P2+P3 结果（2026-11-02）

| 项 | 结果 | 证据 |
|---|---|---|
| P2 前端进 ArkWeb | ✅ | Verge React 前端 `pnpm web:build`（dist 20MB）→ `rawfile/ui/`；index.html 注入 `ohos-shim.js`（Tauri v2 `__TAURI_INTERNALS__` + event 插件模拟）、相对路径、去 `crossorigin`（resource:// 下模块脚本 CORS） |
| P2 IPC shim | ✅ | node 冒烟 PASS：invoke→dispatch→resolve 往返、`plugin:event|listen/emit/unlisten` 语义、错误路径、args JSON（`scripts/ohos-shim.js`） |
| P2 ArkTS dispatcher | ✅ | `ets/bridge/verge-bridge.ets`：核心生命周期/RunState/配置生成、profile 存储（`filesDir`）、代理视图（REST `/proxies` → ProxyViewV1）、延迟测试、Verge 配置存储、VPN 开关；桌面专属命令容错 stub；UI 监督器自动重启核心 |
| P3 VpnExtensionAbility | ✅ 编译+架构 | `ets/vpn/VergeVpnAbility.ets`：`VpnConnection.create()` → fd → runtime.yaml `tun.file-descriptor` → coreStart；`blockedApplications:[自身]` 旁路回环（核心子进程同 UID）；supervisor 自动恢复；状态文件 `verge-vpn-status.txt` |
| P3 跨进程 REST | ✅ | Rust `rest_get` 回退：无本地 core 时从最后 runtime 配置读 external-controller+secret 直连——UI 进程可查 VPN 进程所辖核心（host 测试全绿） |
| 待设备验证 | — | VPN 真机行为（vpndialog 授权、TUN 数据面、DNS）、HAP 安装运行、签名 profile |

**尚未验证（需设备/模拟器或签名 profile）**：HAP 安装与 ohosBridge 页面在真机/模拟器上运行；mihomo 在 OHOS 运行时的 syscall 行为；VpnExtensionAbility TUN 数据面。

## 构建

```bash
scripts/build-core.sh            # mihomo → out/verge-mihomo-ohos-arm64
scripts/build-web.sh             # Verge 前端 → rawfile/ui/（需 code/clash-verge-rev）
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

## 上架合规（AGC「鸿蒙生态规则检测」）

上传 AGC 软件包时，合法性检测里的「**鸿蒙生态规则检测**」（描述为"检测上架分发的鸿蒙应用和元服务是否满足生态的规范性要求"）会静态扫描 APP 包。为满足其规范，本工程已按下表整改（2026-11-07）：

| 检测规则 | 整改前 | 整改后 |
|---|---|---|
| **应用图标**：必须分前景/背景两层、各 1024×1024；禁止系统默认图标 | `app_icon.png` 216px 纯色方块 + `icon.png` 114px DevEco 蓝色四方格**默认模板图标**；`app.json5` 用单层 `$media:app_icon` | 新增 `layered_image.json` + `background.png`（实色不透明）/`foreground.png`（透明底 + V 形代理链路标志），均由 `scripts/gen_icons.py` 生成；`app.json5` 与 `module.json5` 的 EntryAbility `icon` 统一改 `$media:layered_image`；`icon.png`（`startWindowIcon`）与 `app_icon.png` 改为 1024×1024 合成图 |
| **显示名称有意义**：中英文和默认语言都需有意义、非默认值 | 只有 `base/element/string.json`（英文） | 补 `zh_CN` / `en_US` / `base` 三套 `app_name`、Ability 标签与权限 reason |
| **权限说明**：reason 需说明具体场景，不可写"为了功能正常使用" | 泛化英文描述 | 中英文改为具体场景（下载订阅、连接代理节点、建立系统 VPN），并声明不收集个人信息 |
| **应用类型**：Stage 模型需 `bundleType: "app"`（缺省值即 app） | 未显式声明 | `app.json5` 显式加 `"bundleType": "app"` |
| **子进程**：0.3.0 起核心已改进程内加载（`coreStartEmbedded`），不再 spawn | 残留 `maxChildProcess: 8` | 移除该残留字段（缺省即系统默认上限，行为不变） |

图标资源如需重新生成（纯标准库，无第三方依赖）：

```bash
python3 scripts/gen_icons.py app
```

> 注意：AGC 报告里「鸿蒙生态规则检测」是一个**检查项名称**，其"修改意见/详情"会列出具体违规子项。若重新上传后仍不通过，请以报告「详情」中的原文为准，对应到上表规则；常见还有「应用未配置图标的前景图和后景图」「应用名称/图标与系统默认相同」「非预期文件打包检测」等。
> 另：修改代码后需重新打 release 签名的 `.app` 并重新上传；若 AGC 提示版本号已存在，递增 `AppScope/app.json5` 的 `versionCode`。

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

- **P1**：Rust 后端去桌面化移植进 `verge-ohos-bridge`（配置生成/订阅/核心管理）；mihomo 最初以 HAP 内 `libs/arm64` 打包 + 运行时解包执行，0.3.0 起改为 **c-shared 进程内加载**（鸿蒙禁止对应用私有文件 `execve`），详见 `wk/notes/clash-verge-harmony-适配经验-返回键后台与订阅-2026-11-03.md`。
- **P2**：ArkWeb 加载 Verge React 构建产物，`contract.ts` 层 shim `invoke/listen` → ArkTS/JSBridge。
- **P3**：VpnExtensionAbility（TUN→mihomo）+ 长时任务保活；分应用代理受 `CONNECTIVITY_INTERNAL` 系统权限限制（平台约束，明确降级）。
- **P4**：注册 profile → 签名 → 真机（DevEco Testing 云真机可先行）。

上游参照：`code/clash-verge-rev`（v2.5.8）；先例：[ClashBox](https://github.com/xiaobaigroup/ClashBox)、[FlClash-HarmonyOS](https://github.com/shenyingjun5/FlClash-HarmonyOS)。
