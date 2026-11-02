import { webview } from '@kit.ArkWeb'

/**
 * P0 shell: proves the ArkWeb host + JS-bridge direction that the Clash Verge
 * React UI will ride on. `ohosBridge` is the exact seam where the Tauri
 * `invoke/listen` shim lands in P2 (see
 * wk/AIReports/clash-verge-鸿蒙7移植可行性报告-2026-11-02.md, 方案 B).
 */
@Entry
@Component
struct Index {
  controller: webview.WebviewController = new webview.WebviewController()

  build() {
    Column() {
      Web({ src: $rawfile('index.html'), controller: this.controller })
        .javaScriptProxy({
          object: {
            ping: (): string => `pong:${Date.now()}`,
            version: (): string => 'verge-ohos-shell 0.1.0-p0 (API 26)'
          },
          name: 'ohosBridge',
          methodList: ['ping', 'version'],
          controller: this.controller
        })
        .width('100%')
        .height('100%')
        .onlineImageAccess(true)
        .domStorageAccess(true)
    }
    .width('100%')
    .height('100%')
  }
}
