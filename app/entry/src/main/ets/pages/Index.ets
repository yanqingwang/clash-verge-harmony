import { webview } from '@kit.ArkWeb'
import bridge from 'libentry.so'
import common from '@ohos.app.ability.common'
import { hilog } from '@kit.PerformanceAnalysisKit'
import { VergeBridge } from '../bridge/verge-bridge'

/**
 * P2 host: loads the Verge React UI from rawfile/ui and routes every Tauri
 * invoke() through the javaScriptProxy to the ArkTS dispatcher. A supervisor
 * restarts the sidecar core if it dies while the UI expects it running.
 */
@Entry
@Component
struct Index {
  controller: webview.WebviewController = new webview.WebviewController()
  private vb: VergeBridge | null = null
  @State bridgeInfo: string = 'checking bridge…'

  aboutToAppear(): void {
    try {
      const v = bridge.bridgeVersion()
      const p = bridge.ping()
      const st = bridge.coreStatus()
      this.bridgeInfo = `bridge=${v} ping=${p} coreStatus=${st}`
      const ctx = getContext(this) as common.UIAbilityContext
      this.vb = new VergeBridge(this.controller, ctx)
      setInterval(() => {
        if (this.vb !== null && this.vb.coreDesired && !this.vb.coreRunning()) {
          hilog.warn(0x0666, 'Index', 'core died; restarting')
          this.vb.restartCore()
        }
      }, 10000)
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
      Web({ src: $rawfile('ui/index.html'), controller: this.controller })
        .javaScriptProxy({
          object: {
            dispatch: (id: string, cmd: string, argsJson: string): void => {
              if (this.vb !== null) this.vb.dispatch(id, cmd, argsJson)
            },
            ping: (): number => bridge.ping(),
            bridgeVersion: (): string => bridge.bridgeVersion()
          },
          name: 'ohosBridge',
          methodList: ['dispatch', 'ping', 'bridgeVersion'],
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
