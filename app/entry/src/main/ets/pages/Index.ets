import { webview } from '@kit.ArkWeb'
import bridge from 'libentry.so'

/**
 * P0 shell + P1 bridge: ArkWeb host and the NAPI seam where the Tauri
 * `invoke/listen` shim lands in P2 (see
 * wk/AIReports/clash-verge-鸿蒙7移植可行性报告-2026-11-02.md, 方案 B).
 */
@Entry
@Component
struct Index {
  controller: webview.WebviewController = new webview.WebviewController()
  @State bridgeInfo: string = 'checking bridge…'

  aboutToAppear(): void {
    try {
      const v = bridge.bridgeVersion()
      const p = bridge.ping()
      const st = bridge.coreStatus()
      this.bridgeInfo = `bridge=${v} ping=${p} coreStatus=${st}`
    } catch (e) {
      this.bridgeInfo = `bridge error: ${JSON.stringify(e)}`
    }
  }

  build() {
    Column() {
      Text(this.bridgeInfo)
        .fontSize(12)
        .fontColor('#3fb950')
        .padding(4)
        .width('100%')
        .backgroundColor('#161b22')
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
