import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit'
import { hilog } from '@kit.PerformanceAnalysisKit'
import { window } from '@kit.ArkUI'
import { webview } from '@kit.ArkWeb'

const TAG = 'VergeEntry'
const DOMAIN = 0x0000

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // Initialize ArkWeb on the UI thread before the page creates its
    // WebviewController. Lazy init from another thread leaves the engine
    // unable to create a renderer (seen as "Init nweb failed" / blank page).
    webview.WebviewController.initializeWebEngine()
    hilog.info(DOMAIN, TAG, 'onCreate')
  }

  // Called only when the page did not consume the back press (WebView has no
  // history left). Returning true keeps the ability resident in the background
  // instead of destroying it, matching the HarmonyOS system convention.
  onBackPressed(): boolean {
    return true
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'onDestroy')
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'loadContent failed: %{public}s', JSON.stringify(err))
        return
      }
      hilog.info(DOMAIN, TAG, 'loadContent ok')
    })
  }

  onWindowStageDestroy(): void {}

  onForeground(): void {}

  onBackground(): void {}
}
