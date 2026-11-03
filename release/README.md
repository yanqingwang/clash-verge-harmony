# Clash Verge Harmony · release/ 产物说明

**版本：0.2.0**（versionCode 1000001）· bundleName `io.github.clashverge.harmony` · 构建日期 2026-11-03

| 文件 | 用途 | 说明 |
|---|---|---|
| `clash-verge-harmony-0.2.0-signed.hap` | **签名安装包（当前）** | debug profile（DevEco 自动签名），`hap-sign-tool verify-app` 验证通过，可直接 `hdc install` 到真机/模拟器 |
| `clash-verge-harmony-0.2.0-signed.app` | 签名 APP 分发包（当前） | 同上签名 |
| `clash-verge-harmony-0.1.0-*` | 0.1.0 历史产物 | 仅供对照 |
| `SHA256SUMS.txt` | 校验和 | 全部产物 |

## 0.2.0 变更

- **返回键/侧滑 = 应用内后退**：`Index.ets` 页面级 `onBackPress` 先走 ArkWeb 历史（`accessBackward/backward`），根页面再交给系统进后台；`EntryAbility.onBackPressed` 返回 `true` 保持后台驻留，不销毁应用。
- **ArkWeb 提前初始化**：`EntryAbility.onCreate` 调 `webview.WebviewController.initializeWebEngine()`，避免后台线程懒初始化导致渲染进程创建失败。
- **订阅下载改走系统网络栈**：新增 `subscription/subscription-fetcher.ets`（`@ohos.net.http`，异步、系统 DNS/证书），Rust `ureq/rustls` 作为回退；错误原因透传到 UI（`verge_last_error`）。
- **手机布局**：`ohos-shim.js` 注入移动端样式（左侧栏改为底部 Tab、对话框全宽、隐藏桌面拖拽条等）。
- 新增 `get_clash_info` / `get_runtime_config` / `plugin:mihomo|*` 等命令，减少 UI 侧未实现提示。

## 签名信息

- 签名配置：`app/build-profile.json5` signingConfigs `default`（DevEco 自动签名生成）
- 材料：`sign/app-signing.{cer,p12,p7b}`（keyAlias `debugKey`；`sign/` 已 gitignore，勿提交）
- profile：debug，bundleName `io.github.clashverge.harmony`（`sign/app-signing.p7b`）
- **`sign/material` 必须存在**：hvigor 的 `DecipherUtil` 用它解密 build-profile 里的密码。来源 = 账号级 `~/.ohos/config/material`（跨项目共用）。误删会导致 `SignHap` 报 "Signature material verification failed"，恢复方法：`cp -R ~/.ohos/config/material sign/material`
- 验证命令：`java -jar <SDK>/toolchains/lib/hap-sign-tool.jar verify-app -inFile <hap> -outCertChain /tmp/c.cer -outProfile /tmp/p.p7b` → `Verify success`

## 安装

```bash
hdc install -r clash-verge-harmony-0.2.0-signed.hap
```

> 上架需要 release profile：到华为 AGC 申请（大陆网络 + 实名账号），替换 signingConfigs 中 profile/p12 即可，无需改代码。

## 产物内容

- **UI**：Clash Verge React 前端（`rawfile/ui/`，P2，Tauri v2 shim 注入）
- **核心**：`libverge_mihomo.so`（静态 ELF，aarch64）+ `libverge_ohos_bridge.so`（Rust 桥，`libs/{arm64,arm64-v8a}`）
- **NAPI**：`libentry.so`（dlopen 桥接，10 方法，含 `lastError`）
- **VPN**：VpnExtensionAbility（P3，`tun.file-descriptor` 数据面）

命令行复现：`scripts/build-core.sh` + `scripts/build-web.sh` + `scripts/build-hap.sh`（详见仓库 README 与交接指南 `wk/notes/clash-verge-harmony-交接指南-2026-11-02.md`）。
