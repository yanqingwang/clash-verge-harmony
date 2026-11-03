/**
 * verge-bridge.ets — ArkTS side of the Tauri v2 IPC shim.
 *
 * Receives every non-event invoke() from the Verge React UI via the
 * javaScriptProxy `ohosBridge.dispatch(id, cmd, argsJson)` and resolves it
 * with `window.__ohosResolve(id, ok, payloadJson)` through runJavaScript.
 * Events flow back via `window.__ohosEmit(name, payloadJson)`.
 *
 * Command coverage (P2):
 *   - real: core lifecycle, runtime state, profile store, proxy view/delay,
 *           verge config store, VPN start/stop
 *   - tolerant stubs: desktop-only commands return defaults the UI survives
 *   - unknown commands resolve `null` (UI shows a notice, does not crash)
 */
import bridge from 'libentry.so'
import { webview } from '@kit.ArkWeb'
import { fileIo as fs } from '@kit.CoreFileKit'
import { util } from '@kit.ArkTS'
import { hilog } from '@kit.PerformanceAnalysisKit'
import common from '@ohos.app.ability.common'
import Want from '@ohos.app.ability.Want'
import vpnExtension from '@ohos.net.vpnExtension'
import { BusinessError } from '@kit.BasicServicesKit'
import { fetchSubscriptionTo, SubscriptionFetchResult } from '../subscription/subscription-fetcher'

const TAG = 'VergeBridge'
const DOMAIN = 0x0666
const BUNDLE_NAME = 'io.github.clashverge.harmony'
const VPN_ABILITY = 'VergeVpnAbility'
const VPN_STATUS_FILE = 'verge-vpn-status.txt'
const DEFAULT_MIXED_PORT = 7890

/** Payload returned to the UI on a successful subscription download. */
interface SubscriptionOkView {
  bytes: number
  source: string
}

// ---------- payload shapes (mirror src/types/proxy-view.ts + cmds.ts) ----------

interface RunStateView {
  mode: string
  service: string
  serviceUnavailableReason: Object | null
  pendingAction: Object | null
  sidecarAllowed: boolean
  isAdmin: boolean
  opInFlight: boolean
  serviceUsable: boolean
  tunCapable: boolean
  serviceNeedsAttention: boolean
}

interface ProxyViewV1View {
  schemaVersion: number
  orderSource: string
  providerState: string
  global: Object | null
  direct: Object | null
  groups: Array<ProxyGroupViewView>
  records: Record<string, Object>
  standalone: Array<string>
  providers: Array<Object>
}

interface ProxyGroupViewView {
  name: string
  type: string
  alive: boolean
  now: string
  history: Array<Object>
  members: Array<MemberRefView>
  udp: boolean
  xudp: boolean
  tfo: boolean
  mptcp: boolean
  smux: boolean
}

interface MemberRefView {
  kind: string
  name: string
  recordId: string
}

interface ProxyNodeViewView {
  recordId: string
  name: string
  type: string
  alive: boolean
  history: Array<Object>
  source: Object
  udp: boolean
  xudp: boolean
  tfo: boolean
  mptcp: boolean
  smux: boolean
}

interface NodeSourceView {
  kind: string
  proxyName: string
}

interface ProfilesView {
  current: string | null
  items: Array<Object>
}

interface ProfileItemView {
  uid: string
  type: string
  name: string
  url: string
  updated: number
}

interface ListenerOutcomeView {
  ok: boolean
  listener: Object | null
}

interface ListenerDetailView {
  listening: boolean
  address: string
  port: number
}

interface SystemInfoView {
  system_name: string
  system_version: string
  system_kernel_version: string
  system_arch: string
  app_version: string
  app_core_mode: string
  app_is_admin: boolean
}

interface ValidationView {
  status: string
  errors: Array<Object>
}

export class VergeBridge {
  private controller: webview.WebviewController
  private filesDir: string
  private bundleCodeDir: string
  private coreDir: string
  private runtimeConfigPath: string
  private profilesDir: string
  private profilesStorePath: string
  private vergeConfigPath: string
  private vpnStatusPath: string
  coreDesired: boolean = false
  private coreEnsureRequested: boolean = false
  private uptimeStart: number = Date.now()

  constructor(controller: webview.WebviewController, context: common.UIAbilityContext) {
    this.controller = controller
    this.filesDir = context.filesDir
    this.bundleCodeDir = context.bundleCodeDir
    this.coreDir = `${this.filesDir}/clash`
    this.runtimeConfigPath = `${this.coreDir}/runtime.yaml`
    this.profilesDir = `${this.filesDir}/profiles`
    this.profilesStorePath = `${this.filesDir}/profiles.json`
    this.vergeConfigPath = `${this.filesDir}/verge.json`
    this.vpnStatusPath = `${this.filesDir}/${VPN_STATUS_FILE}`
    for (const dir of [this.coreDir, this.profilesDir]) {
      try {
        if (!fs.accessSync(dir)) fs.mkdirSync(dir, true)
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'mkdir %{public}s failed: %{public}s', dir, JSON.stringify(e))
      }
    }
  }

  // ---------- transport ----------

  /**
   * Download a subscription, native netstack first, Rust/ureq fallback.
   *
   * Both `import_profile` and `update_profile` funnel through here so the
   * network call never blocks the ArkTS main thread (the old synchronous
   * `bridge.subscriptionFetch` did) and so every failure carries its real
   * cause back to the UI instead of an opaque `rc=-1`.
   */
  private fetchSubscription(
    id: string,
    url: string,
    outPath: string,
    onSuccess: () => void
  ): void {
    fetchSubscriptionTo(url, outPath)
      .then((res: SubscriptionFetchResult) => this.onSubscriptionFetched(id, url, outPath, res, onSuccess))
      .catch((e: BusinessError) => {
        // Should not happen (fetchSubscriptionTo never throws) but keep the
        // promise contract honest: still fall back before giving up.
        hilog.warn(DOMAIN, TAG, 'native fetch rejected for %{public}s: %{public}s', url, JSON.stringify(e))
        this.rustFallbackFetch(id, url, outPath, `native path threw: ${JSON.stringify(e)}`, onSuccess)
      })
  }

  private onSubscriptionFetched(
    id: string,
    url: string,
    outPath: string,
    res: SubscriptionFetchResult,
    onSuccess: () => void
  ): void {
    if (res.error.length === 0) {
      onSuccess()
      const ok: SubscriptionOkView = { bytes: res.bytes, source: res.source }
      this.resolve(id, true, ok)
      return
    }
    // Native netstack failed (DNS / TLS / HTTP / body). Retry over the Rust
    // ureq/rustls path before surfacing both errors, so a device with a working
    // musl stack still succeeds.
    this.rustFallbackFetch(id, url, outPath, res.error, onSuccess)
  }

  private rustFallbackFetch(
    id: string,
    url: string,
    outPath: string,
    nativeError: string,
    onSuccess: () => void
  ): void {
    let rc = -1
    let err = 'bridge unavailable'
    try {
      rc = bridge.subscriptionFetch(url, outPath)
      if (rc <= 0) err = bridge.lastError()
    } catch (e) {
      err = JSON.stringify(e)
    }
    if (rc > 0) {
      hilog.warn(DOMAIN, TAG, 'native fetch failed (%{public}s) but rustls fallback got %{public}d bytes', nativeError, rc)
      onSuccess()
      const ok: SubscriptionOkView = { bytes: rc, source: 'rustls' }
      this.resolve(id, true, ok)
      return
    }
    this.resolve(id, false, `subscription fetch failed: ${nativeError} | rustls fallback: ${err}`)
  }
  dispatch(id: string, cmd: string, argsJson: string): void {
    hilog.debug(DOMAIN, TAG, 'cmd=%{public}s', cmd)
    let args: Record<string, Object> = {}
    if (argsJson.length > 0) {
      try {
        args = JSON.parse(argsJson) as Record<string, Object>
      } catch (e) {
        args = {}
      }
    }
    try {
      this.handle(id, cmd, args)
    } catch (e) {
      this.resolve(id, false, `verge-bridge: ${JSON.stringify(e)}`)
    }
  }

  private resolve(id: string, ok: boolean, payload: Object | null): void {
    const script = `window.__ohosResolve(${JSON.stringify(id)}, ${ok}, ${JSON.stringify(payload)})`
    this.runJs(script)
  }

  private emit(event: string, payload: Object | null): void {
    const script = `window.__ohosEmit(${JSON.stringify(event)}, ${JSON.stringify(payload)})`
    this.runJs(script)
  }

  private runJs(script: string): void {
    this.controller.runJavaScript(script, (err: BusinessError) => {
      if (err) hilog.warn(DOMAIN, TAG, 'runJs failed: %{public}s', err.message)
    })
  }

  // ---------- helpers ----------

  private str(args: Record<string, Object>, key: string, fallback: string): string {
    const v = args[key]
    return typeof v === 'string' ? v : fallback
  }

  private num(args: Record<string, Object>, key: string, fallback: number): number {
    const v = args[key]
    return typeof v === 'number' ? v : fallback
  }

  private readJsonFile(path: string): Record<string, Object> {
    try {
      if (!fs.accessSync(path)) return {}
      const text = fs.readTextSync(path)
      if (text.length === 0) return {}
      return JSON.parse(text) as Record<string, Object>
    } catch (e) {
      return {}
    }
  }

  private writeJsonFile(path: string, obj: Object): void {
    const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC)
    try {
      fs.writeSync(file.fd, JSON.stringify(obj))
    } finally {
      fs.closeSync(file)
    }
  }

  private readTextFile(path: string): string {
    try {
      if (!fs.accessSync(path)) return ''
      return fs.readTextSync(path)
    } catch (e) {
      return ''
    }
  }

  private writeTextFile(path: string, text: string): void {
    const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC)
    try {
      fs.writeSync(file.fd, text)
    } finally {
      fs.closeSync(file)
    }
  }

  private readProfilesStore(): Record<string, Object> {
    return this.readJsonFile(this.profilesStorePath)
  }

  private saveProfilesStore(store: Record<string, Object>): void {
    this.writeJsonFile(this.profilesStorePath, store)
  }

  private items(store: Record<string, Object>): Array<Object> {
    const v = store['items']
    return Array.isArray(v) ? (v as Array<Object>) : new Array<Object>()
  }

  private findItem(store: Record<string, Object>, uid: string): Record<string, Object> | null {
    for (const it of this.items(store)) {
      const o = it as Record<string, Object>
      if (o['uid'] === uid) return o
    }
    return null
  }

  private profilePath(uid: string): string {
    return `${this.profilesDir}/${uid}.yaml`
  }

  private currentProfileUid(store: Record<string, Object>): string {
    const current = store['current']
    return typeof current === 'string' ? current : ''
  }

  coreRunning(): boolean {
    try {
      // The core is a c-shared library loaded into this process (HarmonyOS
      // forbids execve of app-owned files), so ask the loaded library.
      return bridge.coreIsRunningEmbedded() > 0
    } catch (e) {
      return false
    }
  }

  /** True when the VPN extension owns a traffic-serving core. */
  private vpnActive(): boolean {
    const status = this.readTextFile(this.vpnStatusPath)
    return status === 'started'
  }

  private generateConfig(): void {
    const store = this.readProfilesStore()
    const uid = this.currentProfileUid(store)
    if (uid.length === 0) return
    const profile = this.profilePath(uid)
    if (!fs.accessSync(profile)) return
    bridge.configGenerate(profile, this.runtimeConfigPath)
  }

  /** Start the core when a profile is active; safe to call repeatedly. */
  ensureCore(): void {
    if (this.coreEnsureRequested) return
    try {
      const running = this.coreRunning()
      const vpn = this.vpnActive()
      const uid = this.currentProfileUid(this.readProfilesStore())
      hilog.info(DOMAIN, TAG, 'ensureCore running=%{public}s vpn=%{public}s uid=%{public}s',
        String(running), String(vpn), uid)
      if (!running && !vpn && uid.length > 0) this.startCore()
      this.coreEnsureRequested = true
    } catch (e) {
      // Leave the flag unset so the next get_profiles retries.
      hilog.warn(DOMAIN, TAG, 'ensureCore failed: %{public}s', JSON.stringify(e))
    }
  }

  private startCore(): void {
    // A restart or a repeated toggle must not spawn a second instance.
    if (this.coreRunning()) {
      this.coreDesired = true
      return
    }
    this.generateConfig()
    // If the VPN extension owns the core, do not spawn a second instance in
    // this process (the extension's supervisor restarts it); just regenerate
    // the runtime config so the next VPN start picks up the new profile.
    if (this.vpnActive()) {
      this.coreDesired = false
      return
    }
    const rc = bridge.coreStartEmbedded(this.runtimeConfigPath, this.coreDir)
    hilog.info(DOMAIN, TAG, 'coreStartEmbedded cfg=%{public}s rc=%{public}d running=%{public}d',
      this.runtimeConfigPath, rc, bridge.coreIsRunningEmbedded())
    this.coreDesired = rc === 0
    this.emit('verge://run-state-changed', this.runStatePayload())
  }

  private stopCore(): void {
    bridge.coreStopEmbedded()
    this.coreDesired = false
    this.emit('verge://run-state-changed', this.runStatePayload())
  }

  restartCore(): void {
    this.stopCore()
    this.startCore()
  }

  private runStatePayload(): RunStateView {
    const running = this.coreRunning() || this.vpnActive()
    const state: RunStateView = {
      mode: running ? 'Sidecar' : 'NotRunning',
      service: 'none',
      serviceUnavailableReason: null,
      pendingAction: null,
      sidecarAllowed: true,
      isAdmin: true,
      opInFlight: false,
      serviceUsable: false,
      tunCapable: true,
      serviceNeedsAttention: false,
    }
    return state
  }

  private proxyViewPayload(): ProxyViewV1View {
    const empty: ProxyViewV1View = {
      schemaVersion: 1,
      orderSource: 'runtime',
      providerState: 'ready',
      global: null,
      direct: null,
      groups: new Array<ProxyGroupViewView>(),
      records: {},
      standalone: new Array<string>(),
      providers: new Array<Object>(),
    }
    if (!this.coreRunning() && !this.vpnActive()) return empty
    const raw = bridge.coreRestGet('/proxies')
    if (raw.length === 0) {
      hilog.warn(DOMAIN, TAG, 'proxyView REST empty: %{public}s', bridge.lastError())
    }
    if (raw.length === 0) return empty
    try {
      const data = JSON.parse(raw) as Record<string, Object>
      // mihomo GET /proxies returns {"proxies": {"<name>": {...}}}. Selector,
      // url-test, fallback and load-balance entries carry "all"; those are the
      // groups. Group members may themselves be groups, so every member must
      // resolve either as a node record or as a group reference — the UI throws
      // "Proxy view record not found" otherwise.
      const proxMap = data['proxies']
      const entries: Array<Object> = new Array<Object>()
      if (proxMap !== undefined && proxMap !== null && typeof proxMap === 'object') {
        const m = proxMap as Record<string, Object>
        for (const key of Object.keys(m)) entries.push(m[key] as Object)
      }
      const groupNames: Record<string, boolean> = {}
      for (const e of entries) {
        const o = e as Record<string, Object>
        if (Array.isArray(o['all'])) groupNames[o['name'] as string] = true
      }
      const records: Record<string, Object> = {}
      for (const e of entries) {
        const o = e as Record<string, Object>
        const name = o['name'] as string
        const history: Array<Object> = Array.isArray(o['history']) ? (o['history'] as Array<Object>) : new Array<Object>()
        const src: NodeSourceView = { kind: 'core', proxyName: name }
        const node: ProxyNodeViewView = {
          recordId: name,
          name,
          type: o['type'] !== undefined ? (o['type'] as string) : 'Shadowsocks',
          alive: o['alive'] !== false,
          history,
          source: src,
          udp: o['udp'] === true,
          xudp: false,
          tfo: o['tfo'] === true,
          mptcp: false,
          smux: false,
        }
        records[name] = node
      }
      const groups: Array<ProxyGroupViewView> = new Array<ProxyGroupViewView>()
      let globalGroup: ProxyGroupViewView | null = null
      for (const e of entries) {
        const o = e as Record<string, Object>
        const name = o['name'] as string
        if (!Array.isArray(o['all'])) continue
        const all: Array<Object> = o['all'] as Array<Object>
        const members: Array<MemberRefView> = new Array<MemberRefView>()
        for (const n of all) {
          const memberName = n as string
          const isGroup = groupNames[memberName] === true
          const ref: MemberRefView = {
            kind: isGroup ? 'group' : 'node',
            name: memberName,
            recordId: isGroup ? '' : memberName,
          }
          members.push(ref)
        }
        const group: ProxyGroupViewView = {
          name,
          type: o['type'] !== undefined ? (o['type'] as string) : 'Selector',
          alive: true,
          now: o['now'] !== undefined ? (o['now'] as string) : '',
          history: new Array<Object>(),
          members,
          udp: false,
          xudp: false,
          tfo: false,
          mptcp: false,
          smux: false,
        }
        groups.push(group)
        if (name === 'GLOBAL') globalGroup = group
      }
      const standalone: Array<string> = new Array<string>()
      for (const e of entries) {
        const o = e as Record<string, Object>
        const name = o['name'] as string
        if (groupNames[name] !== true && name !== 'DIRECT' && name !== 'REJECT') {
          standalone.push(name)
        }
      }
      const view: ProxyViewV1View = {
        schemaVersion: 1,
        orderSource: 'runtime',
        providerState: 'ready',
        global: globalGroup,
        direct: records['DIRECT'] !== undefined ? records['DIRECT'] : null,
        groups,
        records,
        standalone,
        providers: new Array<Object>(),
      }
      return view
    } catch (e) {
      return empty
    }
  }

  private baseConfigPayload(): Object {
    const raw = this.restConfigs()
    const map: Record<string, string> = {
      'socks-port': 'socksPort',
      'redir-port': 'redirPort',
      'tproxy-port': 'tproxyPort',
      'mixed-port': 'mixedPort',
      'allow-lan': 'allowLan',
      'bind-address': 'bindAddress',
      'log-level': 'logLevel',
      'unified-delay': 'unifiedDelay',
      'interface-name': 'interfaceName',
      'find-process-mode': 'findProcessMode',
      'tcp-concurrent': 'tcpConcurrent',
      'external-controller': 'externalController',
      'external-controller-cors': 'externalControllerCors',
    }
    const out: Record<string, Object> = {}
    for (const k of Object.keys(raw)) {
      const nk = map[k] !== undefined ? map[k] : k
      out[nk] = raw[k]
    }
    return out
  }

  /** mihomo GET /configs, or defaults when the core is not running. */
  private restConfigs(): Record<string, Object> {
    if (this.coreRunning() || this.vpnActive()) {
      try {
        const raw = JSON.parse(bridge.coreRestGet('/configs')) as Record<string, Object>
        if (Object.keys(raw).length > 0) return raw
      } catch (e) {
        // fall through to defaults
      }
    }
    const d: Record<string, Object> = {}
    d['port'] = 0
    d['socks-port'] = 0
    d['redir-port'] = 0
    d['tproxy-port'] = 0
    d['mixed-port'] = DEFAULT_MIXED_PORT
    d['allow-lan'] = false
    d['mode'] = 'rule'
    d['log-level'] = 'info'
    d['ipv6'] = false
    return d
  }

  // ---------- command dispatch ----------

  private handle(id: string, cmd: string, args: Record<string, Object>): void {
    switch (cmd) {
      case 'get_runtime_state':
        this.resolve(id, true, this.runStatePayload())
        return
      case 'get_app_uptime':
        this.resolve(id, true, Math.floor((Date.now() - this.uptimeStart) / 1000))
        return
      case 'get_verge_config':
        this.resolve(id, true, this.readJsonFile(this.vergeConfigPath))
        return
      case 'patch_verge_config': {
        // The UI sends { payload: {...} }; older callers used { config: {...} }.
        const raw = args['payload'] !== undefined ? args['payload'] : args['config']
        const patch = raw as Record<string, Object>
        const store = this.readJsonFile(this.vergeConfigPath)
        if (patch !== undefined) {
          for (const k of Object.keys(patch)) store[k] = patch[k]
        }
        this.writeJsonFile(this.vergeConfigPath, store)
        // The desktop backend applies these switches as side effects; without
        // them the UI flips a toggle while the core never starts.
        if (patch !== undefined && patch['enable_system_proxy'] !== undefined) {
          if (patch['enable_system_proxy'] === true) {
            this.startCore()
          } else if (store['enable_tun_mode'] !== true) {
            this.stopCore()
          }
        }
        if (patch !== undefined && patch['enable_tun_mode'] !== undefined) {
          if (patch['enable_tun_mode'] === true) {
            this.startVpn()
          } else {
            this.stopVpn()
          }
        }
        this.emit('verge://refresh-verge-config', '')
        this.resolve(id, true, null)
        return
      }
      case 'get_profiles': {
        // The UI asks for profiles right after load; resume the core here so a
        // failed startup attempt still gets one retry once the page is alive.
        this.ensureCore()
        const store = this.readProfilesStore()
        const cur = store['current']
        const current = typeof cur === 'string' && cur.length > 0 ? cur : null
        const view: ProfilesView = { current, items: this.items(store) }
        this.resolve(id, true, view)
        return
      }
      case 'patch_profiles_config': {
        const patch = args['profiles'] as Record<string, Object>
        if (patch !== undefined) {
          // The UI patches one field at a time (e.g. only `current` when a
          // profile is activated), so merge into the stored config instead of
          // replacing it — replacing would drop the imported items.
          const store = this.readProfilesStore()
          const previous = store['current']
          for (const k of Object.keys(patch)) store[k] = patch[k]
          this.saveProfilesStore(store)
          if (patch['current'] !== undefined && patch['current'] !== previous) {
            this.restartCore()
          }
        }
        this.emit('verge://refresh-profiles', '')
        const outcome: ValidationView = { status: 'valid', errors: new Array<Object>() }
        this.resolve(id, true, outcome)
        return
      }
      case 'create_profile': {
        const item = args['item'] as Record<string, Object>
        const fileData = args['fileData']
        if (item !== undefined) {
          const uid = item['uid'] as string
          if (fileData !== null && fileData !== undefined) {
            this.writeTextFile(this.profilePath(uid), String(fileData))
          }
          const store = this.readProfilesStore()
          const items = this.items(store)
          items.push(item)
          store['items'] = items
          this.saveProfilesStore(store)
        }
        this.emit('verge://refresh-profiles', '')
        this.resolve(id, true, null)
        return
      }
      case 'import_profile': {
        const url = this.str(args, 'url', '')
        if (url.length === 0) {
          this.resolve(id, false, 'import_profile: missing url')
          return
        }
        const uid = util.generateRandomUUID(true)
        const outPath = this.profilePath(uid)
        this.fetchSubscription(id, url, outPath, () => {
          // Runs after a successful fetch: register the profile item.
          const store = this.readProfilesStore()
          const item: ProfileItemView = {
            uid,
            type: 'remote',
            name: this.urlName(url),
            url,
            updated: Math.floor(Date.now() / 1000),
          }
          const items = this.items(store)
          items.push(item)
          // items() hands back a fresh array when the store has none yet, so it
          // must be written back before saving.
          store['items'] = items
          // First import becomes the active profile, so the core has something
          // to load without an extra tap.
          const current = store['current']
          const autoActivated = typeof current !== 'string' || current.length === 0
          if (autoActivated) store['current'] = uid
          this.saveProfilesStore(store)
          hilog.info(DOMAIN, TAG, 'import_profile saved items=%{public}d', items.length)
          this.emit('verge://refresh-profiles', '')
          if (autoActivated) {
            this.emit('verge://refresh-clash-config', '')
            this.startCore()
          }
        })
        return
      }
      case 'update_profile': {
        const uid = this.str(args, 'index', '')
        const item = this.findItem(this.readProfilesStore(), uid)
        if (item === null || typeof item['url'] !== 'string') {
          this.resolve(id, false, 'update_profile: profile not found')
          return
        }
        const url = item['url'] as string
        const outPath = this.profilePath(uid)
        this.fetchSubscription(id, url, outPath, () => {
          item['updated'] = Math.floor(Date.now() / 1000)
          this.saveProfilesStore(this.readProfilesStore())
          this.emit('verge://refresh-profiles', '')
        })
        return
      }
      case 'delete_profile': {
        const uid = this.str(args, 'index', '')
        const store = this.readProfilesStore()
        const items = this.items(store)
        const idx = items.findIndex((it) => (it as Record<string, Object>)['uid'] === uid)
        if (idx >= 0) {
          items.splice(idx, 1)
          try {
            fs.unlinkSync(this.profilePath(uid))
          } catch (e) {
            // file may not exist
          }
          if (store['current'] === uid) store['current'] = ''
          this.saveProfilesStore(store)
        }
        this.emit('verge://refresh-profiles', '')
        this.resolve(id, true, null)
        return
      }
      case 'reorder_profile': {
        const activeId = this.str(args, 'activeId', '')
        const overId = this.str(args, 'overId', '')
        const store = this.readProfilesStore()
        const items = this.items(store)
        const from = items.findIndex((it) => (it as Record<string, Object>)['uid'] === activeId)
        const to = items.findIndex((it) => (it as Record<string, Object>)['uid'] === overId)
        if (from >= 0 && to >= 0 && from !== to) {
          const moved = items.splice(from, 1)[0]
          items.splice(to, 0, moved)
          this.saveProfilesStore(store)
        }
        this.emit('verge://refresh-profiles', '')
        this.resolve(id, true, null)
        return
      }
      case 'view_profile': {
        const uid = this.str(args, 'index', '')
        const store = this.readProfilesStore()
        if (this.findItem(store, uid) !== null) {
          store['current'] = uid
          this.saveProfilesStore(store)
          if (this.coreRunning()) this.restartCore()
          else this.startCore()
        }
        this.emit('verge://refresh-clash-config', '')
        this.resolve(id, true, null)
        return
      }
      case 'read_profile_file': {
        const uid = this.str(args, 'index', '')
        this.resolve(id, true, this.readTextFile(this.profilePath(uid)))
        return
      }
      case 'save_profile_file': {
        const uid = this.str(args, 'index', '')
        const content = args['fileData']
        if (typeof content === 'string') this.writeTextFile(this.profilePath(uid), content)
        const outcome: ValidationView = { status: 'valid', errors: new Array<Object>() }
        this.resolve(id, true, outcome)
        return
      }
      case 'enhance_profiles': {
        const outcome: ValidationView = { status: 'valid', errors: new Array<Object>() }
        this.resolve(id, true, outcome)
        return
      }
      case 'get_proxy_view':
        this.resolve(id, true, this.proxyViewPayload())
        return
      case 'test_delay': {
        const url = this.str(args, 'url', '')
        const delay = this.testDelay(url)
        this.resolve(id, true, delay)
        return
      }
      case 'probe_listener': {
        const running = this.coreRunning()
        const listener: ListenerOutcomeView = {
          ok: running,
          listener: null,
        }
        if (running) {
          const detail: ListenerDetailView = {
            listening: true,
            address: '127.0.0.1',
            port: DEFAULT_MIXED_PORT,
          }
          listener.listener = detail
        }
        this.resolve(id, true, listener)
        return
      }
      case 'patch_clash_mode': {
        const mode = this.str(args, 'payload', 'rule')
        const yaml = this.readTextFile(this.runtimeConfigPath)
        if (yaml.length > 0) {
          const patched = yaml.replace(/^mode:.*$/m, `mode: ${mode}`)
          this.writeTextFile(this.runtimeConfigPath, patched)
          if (this.coreRunning()) this.restartCore()
        }
        this.resolve(id, true, null)
        return
      }
      case 'patch_clash_config': {
        // P2: regenerate from the active profile (patch payload not yet
        // merged — see P4 TODO in the handover doc).
        if (this.coreRunning()) this.restartCore()
        this.resolve(id, true, null)
        return
      }
      case 'restart_core':
        this.restartCore()
        this.resolve(id, true, null)
        return
      case 'get_system_info': {
        const info: SystemInfoView = {
          system_name: 'HarmonyOS',
          system_version: '5.0',
          system_kernel_version: '',
          system_arch: 'aarch64',
          app_version: '0.1.0-ohos',
          app_core_mode: this.coreRunning() ? 'sidecar' : 'none',
          app_is_admin: true,
        }
        this.resolve(id, true, info)
        return
      }
      case 'get_clash_info': {
        const info: Record<string, Object> = {}
        info['mixed_port'] = DEFAULT_MIXED_PORT
        info['port'] = 0
        info['socks_port'] = 0
        info['redir_port'] = 0
        info['tproxy_port'] = 0
        info['server'] = '127.0.0.1:9090'
        info['secret'] = ''
        this.resolve(id, true, info)
        return
      }
      case 'get_runtime_config':
        this.resolve(id, true, this.restConfigs())
        return
      case 'get_runtime_yaml': {
        const yaml = this.readTextFile(this.runtimeConfigPath)
        this.resolve(id, true, yaml.length > 0 ? yaml : null)
        return
      }
      case 'get_runtime_logs': {
        const logs: Record<string, Object> = {}
        this.resolve(id, true, logs)
        return
      }
      case 'get_sys_proxy': {
        const cfg = this.readJsonFile(this.vergeConfigPath)
        const sp: Record<string, Object> = {}
        sp['enable'] = cfg['enable_system_proxy'] === true
        sp['server'] = `127.0.0.1:${DEFAULT_MIXED_PORT}`
        sp['bypass'] = ''
        this.resolve(id, true, sp)
        return
      }
      case 'get_auto_proxy': {
        const ap: Record<string, Object> = {}
        ap['enable'] = false
        ap['url'] = ''
        this.resolve(id, true, ap)
        return
      }
      case 'take_discarded_keys_notice':
        this.resolve(id, true, null)
        return
      case 'plugin:mihomo|get_base_config':
        this.resolve(id, true, this.baseConfigPayload())
        return
      case 'plugin:mihomo|get_rules':
      case 'plugin:mihomo|get_rule_providers':
      case 'plugin:mihomo|get_providers_proxies': {
        const path = cmd === 'plugin:mihomo|get_rules'
          ? '/rules'
          : cmd === 'plugin:mihomo|get_rule_providers' ? '/providers/rules' : '/providers/proxies'
        if (!this.coreRunning() && !this.vpnActive()) {
          const emptyRules: Record<string, Object> = { 'rules': [] }
          this.resolve(id, true, emptyRules)
          return
        }
        try {
          const body = JSON.parse(bridge.coreRestGet(path)) as Record<string, Object>
          this.resolve(id, true, body)
        } catch (e) {
          this.resolve(id, false, `core rest ${path} failed`)
        }
        return
      }
      case 'plugin:mihomo|update_rule_provider':
      case 'plugin:mihomo|clear_all_ws_connections':
        this.resolve(id, true, null)
        return
      case 'plugin:mihomo|reload_config':
        if (this.coreRunning()) this.restartCore()
        this.resolve(id, true, null)
        return
      case 'get_pending_failures':
        this.resolve(id, true, new Array<Object>())
        return
      case 'get_sidecar_failure':
        this.resolve(id, true, null)
        return
      case 'get_app_dir':
        this.resolve(id, true, this.filesDir)
        return
      case 'get_system_hostname':
        this.resolve(id, true, '')
        return
      case 'get_embedded_server_port':
        this.resolve(id, true, 0)
        return
      case 'get_runtime_proxy_chain_config':
        this.resolve(id, true, '')
        return
      case 'download_icon_cache':
        this.resolve(id, true, '')
        return
      case 'check_media_unlock_item':
        this.resolve(id, true, null)
        return
      case 'take_dns_override_notice':
      case 'take_service_repair_notice':
        this.resolve(id, true, false)
        return
      case 'validate_dns_config': {
        const outcome: ValidationView = { status: 'valid', errors: new Array<Object>() }
        this.resolve(id, true, outcome)
        return
      }
      case 'vpn_start':
        this.startVpn()
        this.resolve(id, true, null)
        return
      case 'vpn_stop':
        this.stopVpn()
        this.resolve(id, true, null)
        return
      case 'vpn_status':
        this.resolve(id, true, this.readTextFile(this.vpnStatusPath))
        return
      default:
        // Desktop-only / unimplemented commands: tolerate with null.
        this.resolve(id, true, null)
        return
    }
  }

  // ---------- vpn (P3) ----------

  private startVpn(): void {
    const want: Want = {
      bundleName: BUNDLE_NAME,
      abilityName: VPN_ABILITY,
    }
    vpnExtension.startVpnExtensionAbility(want).then(() => {
      hilog.info(DOMAIN, TAG, 'startVpnExtensionAbility ok')
    }).catch((e: BusinessError) => {
      hilog.error(DOMAIN, TAG, 'start failed: %{public}s', e.message)
      // The extension did not start (permission denied, no VPN dialog on this
      // image, ...): revert the toggle so the UI does not claim TUN is on.
      const store = this.readJsonFile(this.vergeConfigPath)
      store['enable_tun_mode'] = false
      this.writeJsonFile(this.vergeConfigPath, store)
      this.emit('verge://refresh-verge-config', '')
      this.emit('verge://notice-message', ['error', `VPN start failed: ${e.message}`])
    })
  }

  private stopVpn(): void {
    const want: Want = {
      bundleName: BUNDLE_NAME,
      abilityName: VPN_ABILITY,
    }
    vpnExtension.stopVpnExtensionAbility(want).catch((e: BusinessError) => {
      hilog.error(DOMAIN, TAG, 'stop failed: %{public}s', e.message)
    })
  }

  // ---------- core queries ----------

  private testDelay(url: string): number {
    if (!this.coreRunning() && !this.vpnActive()) return 0
    try {
      const raw = JSON.parse(bridge.coreRestGet('/proxies')) as Record<string, Object>
      const groups: Array<Object> = Array.isArray(raw['groups'])
        ? (raw['groups'] as Array<Object>)
        : new Array<Object>()
      if (groups.length === 0) return 0
      const g = groups[0] as Record<string, Object>
      const groupName = g['name'] as string
      const now = g['now'] as string
      if (now.length === 0) return 0
      const path = `/proxies/${encodeURIComponent(groupName)}/${encodeURIComponent(now)}/delay?url=${encodeURIComponent(url)}`
      const resp = JSON.parse(bridge.coreRestGet(path)) as Record<string, Object>
      const delay = resp['delay']
      return typeof delay === 'number' ? delay as number : 0
    } catch (e) {
      return 0
    }
  }

  private urlName(url: string): string {
    try {
      // Drop query/fragment and trailing slashes so the card shows a stable
      // name instead of "<id>?token=…".
      const clean = url.split('#')[0].split('?')[0].replace(/\/+$/, '')
      const last = clean.split('/').pop()
      return last !== undefined && last.length > 0 ? last : url
    } catch (e) {
      return url
    }
  }
}
