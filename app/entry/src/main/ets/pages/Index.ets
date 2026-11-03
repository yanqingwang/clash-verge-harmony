import { webview } from '@kit.ArkWeb'
import bridge from 'libentry.so'
import common from '@ohos.app.ability.common'
import { hilog } from '@kit.PerformanceAnalysisKit'
import { VergeBridge } from '../bridge/verge-bridge'

const DOMAIN = 0x0666
const APPASSETS = 'https://appassets.local/'

/**
 * App shell: hosts the Verge React UI in ArkWeb.
 *
 * The frontend is served through onInterceptRequest from the HAP rawfile at
 * the virtual origin https://appassets.local/ — this gives every asset a
 * proper MIME type and a real https origin, so ES modules, classic scripts
 * and same-origin fetches all behave exactly like a normal web app
 * (loading rawfile directly does not execute scripts reliably).
 */
@Entry
@Component
struct Index {
  controller: webview.WebviewController = new webview.WebviewController()
  private vb: VergeBridge | null = null
  @State bridgeInfo: string = 'checking bridge…'

  // Back key / edge swipe: navigate the hosted UI's history first (in-app back);
  // only at its root return false, which lets EntryAbility.onBackPressed move
  // the app to the background rather than closing it.
  onBackPress(): boolean {
    try {
      if (this.controller.accessBackward()) {
        this.controller.backward()
        return true
      }
    } catch (e) {
      hilog.warn(DOMAIN, 'Index', 'backward failed: %{public}s', JSON.stringify(e))
    }
    return false
  }

  aboutToAppear(): void {
    try {
      const v = bridge.bridgeVersion()
      const p = bridge.ping()
      const ctx = getContext(this) as common.UIAbilityContext
      this.vb = new VergeBridge(this.controller, ctx)
      // Resume the core if a profile was active when the app was last closed.
      // A native hiccup here must not blank out the bridge status line.
      try {
        this.vb.ensureCore()
      } catch (e) {
        hilog.warn(DOMAIN, 'Index', 'ensureCore failed: %{public}s', JSON.stringify(e))
      }
      const st = bridge.coreIsRunningEmbedded()
      this.bridgeInfo = `bridge=${v} ping=${p} core=${st > 0 ? 'running' : 'stopped'}`
      setInterval(() => {
        if (this.vb !== null && this.vb.coreDesired && !this.vb.coreRunning()) {
          hilog.warn(DOMAIN, 'Index', 'core died; restarting')
          this.vb.restartCore()
        }
      }, 10000)
    } catch (e) {
      hilog.error(DOMAIN, 'Index', 'aboutToAppear error: %{public}s', JSON.stringify(e))
      this.bridgeInfo = `bridge error: ${JSON.stringify(e)}`
    }
  }

  private mimeOf(path: string): string {
    if (path.endsWith('.html') || path.endsWith('.htm')) return 'text/html'
    if (path.endsWith('.js') || path.endsWith('.mjs')) return 'text/javascript'
    if (path.endsWith('.css')) return 'text/css'
    if (path.endsWith('.json')) return 'application/json'
    if (path.endsWith('.ico')) return 'image/vnd.microsoft.icon'
    if (path.endsWith('.png')) return 'image/png'
    if (path.endsWith('.svg')) return 'image/svg+xml'
    if (path.endsWith('.woff2')) return 'font/woff2'
    if (path.endsWith('.ttf')) return 'font/ttf'
    if (path.endsWith('.webp')) return 'image/webp'
    return 'application/octet-stream'
  }

  private notFound(): WebResourceResponse {
    const resp = new WebResourceResponse()
    resp.setResponseData('')
    resp.setResponseMimeType('text/plain')
    resp.setResponseCode(404)
    resp.setReasonMessage('Not Found')
    return resp
  }

  private isBinary(path: string): boolean {
    return path.endsWith('.png') || path.endsWith('.ico') || path.endsWith('.woff2') ||
      path.endsWith('.ttf') || path.endsWith('.webp') || path.endsWith('.svg')
  }

  private intercept(url: string): WebResourceResponse {
    const prefix = APPASSETS
    if (!url.startsWith(prefix)) return this.notFound()
    let path = url.substring(prefix.length)
    const q = path.indexOf('?')
    if (q >= 0) path = path.substring(0, q)
    if (path.length === 0 || path.endsWith('/')) path += 'index.html'
    if (path.includes('..')) return this.notFound()
    try {
      const ctx = getContext(this) as common.UIAbilityContext
      const data = ctx.resourceManager.getRawFileContentSync(`ui/${path}`)
      const resp = new WebResourceResponse()
      resp.setResponseData(data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength))
      resp.setResponseMimeType(this.mimeOf(path))
      if (!this.isBinary(path)) {
        resp.setResponseEncoding('utf-8')
      }
      resp.setResponseCode(200)
      resp.setReasonMessage('OK')
      resp.setResponseHeader([{ headerKey: 'Access-Control-Allow-Origin', headerValue: '*' }])
      return resp
    } catch (e) {
      hilog.warn(DOMAIN, 'Index', 'intercept miss: %{public}s', path)
      return this.notFound()
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

      Web({ src: APPASSETS, controller: this.controller })
        .layoutWeight(1)
        .width('100%')
        .javaScriptAccess(true)
        .domStorageAccess(true)
        .onlineImageAccess(true)
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
        .onInterceptRequest((event) => {
          return this.intercept(event.request.getRequestUrl())
        })
        .onConsole((event) => {
          hilog.info(DOMAIN, 'WebConsole', '%{public}s', event.message.getMessage())
          return false
        })
        .onErrorReceive((event) => {
          hilog.error(DOMAIN, 'WebErr', 'url=%{public}s code=%{public}s info=%{public}s',
            event.request.getRequestUrl(), event.error.getErrorCode(), event.error.getErrorInfo())
        })
        .onPageEnd((event) => {
          hilog.info(DOMAIN, 'PageEnd', 'url=%{public}s', event.url)
        })
        .onPageBegin((event) => {
          hilog.info(DOMAIN, 'PageBegin', 'url=%{public}s', event.url)
        })
    }
    .width('100%')
    .height('100%')
  }
}
