# Clash Verge Harmony · release/ 产物说明

**版本：0.1.0**（versionCode 1000000）· bundleName `io.github.clashverge.harmony` · 构建日期 2026-11-02

| 文件 | 用途 | 说明 |
|---|---|---|
| `clash-verge-harmony-0.1.0-signed.hap` | **签名安装包** | debug profile（DevEco 自动签名），`hap-sign-tool verify-app` 验证通过，可直接 `hdc install` 到真机/模拟器 |
| `clash-verge-harmony-0.1.0-signed.app` | 签名 APP 分发包 | 同上签名 |
| `clash-verge-harmony-0.1.0-unsigned.hap/.app` | 未签名对照 | 早期产物，仅供对照 |
| `SHA256SUMS.txt` | 校验和 | 全部四个产物 |

## 签名信息

- 签名配置：`app/build-profile.json5` signingConfigs `default`（DevEco 自动签名生成）
- 材料：`sign/app-signing.{cer,p12,p7b}`（keyAlias `debugKey`；`sign/` 已 gitignore，勿提交）
- profile：debug，bundleName `io.github.clashverge.harmony`（`sign/app-signing.p7b`）
- **`sign/material` 必须存在**：hvigor 的 `DecipherUtil` 用它解密 build-profile 里的密码。来源 = 账号级 `~/.ohos/config/material`（跨项目共用）。误删会导致 `SignHap` 报 "Signature material verification failed"，恢复方法：`cp -R ~/.ohos/config/material sign/material`
- 验证命令：`java -jar <SDK>/toolchains/lib/hap-sign-tool.jar verify-app -inFile <hap> -outCertChain /tmp/c.cer -outProfile /tmp/p.p7b` → `Verify success`

## 安装

```bash
hdc install -r clash-verge-harmony-0.1.0-signed.hap
```

> 上架需要 release profile：到华为 AGC 申请（大陆网络 + 实名账号），替换 signingConfigs 中 profile/p12 即可，无需改代码。

## 产物内容

- **UI**：Clash Verge React 前端（`rawfile/ui/`，P2，Tauri v2 shim 注入）
- **核心**：`libverge_mihomo.so`（静态 ELF，aarch64）+ `libverge_ohos_bridge.so`（Rust 桥，`libs/{arm64,arm64-v8a}`）
- **NAPI**：`libentry.so`（dlopen 桥接，9 方法）
- **VPN**：VpnExtensionAbility（P3，`tun.file-descriptor` 数据面）

命令行复现：`scripts/build-core.sh` + `scripts/build-web.sh` + `scripts/build-hap.sh`（详见仓库 README 与交接指南 `wk/notes/clash-verge-harmony-交接指南-2026-11-02.md`）。
