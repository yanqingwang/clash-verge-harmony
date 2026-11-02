# Clash Verge Harmony · release/ 产物说明

**版本：0.1.0**（versionCode 1000000）· bundleName `io.github.clashverge.harmony` · 构建日期 2026-11-02（release mode）

| 文件 | 用途 | 说明 |
|---|---|---|
| `clash-verge-harmony-0.1.0-unsigned.hap` | 安装包（entry 模块） | **未签名**。真机/模拟器安装需先签名（见下） |
| `clash-verge-harmony-0.1.0-unsigned.app` | 应用分发包（APP bundle） | 未签名；含 entry 模块，供上架/侧载流程使用 |
| `SHA256SUMS.txt` | 校验和 | 两个产物的 sha256 |

## 产物内容

- **UI**：Clash Verge React 前端（`rawfile/ui/`，P2，Tauri v2 shim 注入）
- **核心**：`libverge_mihomo.so`（静态 ELF，aarch64）+ `libverge_ohos_bridge.so`（Rust 桥，`libs/{arm64,arm64-v8a}`）
- **NAPI**：`libentry.so`（dlopen 桥接，9 方法）
- **VPN**：VpnExtensionAbility（P3，`tun.file-descriptor` 数据面）

## 安装前置（重要）

1. **签名**：未签名 HAP 无法直接安装。两种方式：
   - DevEco Studio → Project Structure → Signing Configs → **Automatically generate signature**（需实名华为账号 + 大陆网络），自动为 `io.github.clashverge.harmony` 生成 debug profile 并签名。
   - 或为正式分发注册 release profile（华为 AGC）。
2. **设备**：模拟器（DevEco Device Manager）或真机（hdc）。运行后验证：UI 加载 → 订阅导入 → 核心起停 → VPN 开关。
3. 命令行复现：`scripts/build-core.sh` + `scripts/build-web.sh` + `scripts/build-hap.sh`（详见仓库 README 与交接指南 `wk/notes/clash-verge-harmony-交接指南-2026-11-02.md`）。
