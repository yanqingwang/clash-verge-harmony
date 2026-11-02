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

const TAG = 'VergeBridge'
const DOMAIN = 0x0666
const BUNDLE_NAME = 'io.github.clashverge.harmony'
const VPN_ABILITY = 'VergeVpnAbility'
const VPN_STATUS_FILE = 'verge-vpn-status.txt'
const DEFAULT_MIXED_PORT = 7890

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
  private coreBinPath: string
  coreDesired: boolean = false
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
    this.coreBinPath = this.resolveCoreBinPath()
  }

  private resolveCoreBinPath(): string {
    const candidates: string[] = [
      `${this.bundleCodeDir}/libs/arm64/libverge_mihomo.so`,
      `${this.bundleCodeDir}/libs/arm64-v8a/libverge_mihomo.so`,
    ]
    for (const p of candidates) {
      try {
        if (fs.accessSync(p)) return p
      } catch (e) {
        // keep probing
      }
    }
    return candidates[0]
  }

  // ---------- transport ----------

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
      return bridge.coreStatus() > 0
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

  private startCore(): void {
    this.generateConfig()
    // If the VPN extension owns the core, do not spawn a second instance in
    // this process (the extension's supervisor restarts it); just regenerate
    // the runtime config so the next VPN start picks up the new profile.
    if (this.vpnActive()) {
      this.coreDesired = false
      return
    }
    const pid = bridge.coreStart(this.coreBinPath, this.coreDir, this.runtimeConfigPath)
    this.coreDesired = pid > 0
    this.emit('verge://run-state-changed', this.runStatePayload())
  }

  private stopCore(): void {
    bridge.coreStop()
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
    if (raw.length === 0) return empty
    try {
      const data = JSON.parse(raw) as Record<string, Object>
      const rawGroups: Array<Object> = Array.isArray(data['groups'])
        ? (data['groups'] as Array<Object>)
        : new Array<Object>()
      const rawProxies: Array<Object> = Array.isArray(data['proxies'])
        ? (data['proxies'] as Array<Object>)
        : new Array<Object>()
      const records: Record<string, Object> = {}
      for (const p of rawProxies) {
        const o = p as Record<string, Object>
        const name = o['name'] as string
        const history: Array<Object> = Array.isArray(o['history']) ? (o['history'] as Array<Object>) : new Array<Object>()
        const src: NodeSourceView = { kind: 'core', proxyName: name }
        const node: ProxyNodeViewView = {
          recordId: name,
          name,
          type: o['type'] !== undefined ? (o['type'] as string) : 'Shadowsocks',
          alive: o['alive'] === true,
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
      for (const g of rawGroups) {
        const o = g as Record<string, Object>
        const name = o['name'] as string
        const all: Array<Object> = Array.isArray(o['all']) ? (o['all'] as Array<Object>) : new Array<Object>()
        const members: Array<MemberRefView> = new Array<MemberRefView>()
        for (const n of all) {
          const ref: MemberRefView = { kind: 'node', name: n as string, recordId: n as string }
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
      }
      const view: ProxyViewV1View = {
        schemaVersion: 1,
        orderSource: 'runtime',
        providerState: 'ready',
        global: null,
        direct: null,
        groups,
        records,
        standalone: new Array<string>(),
        providers: new Array<Object>(),
      }
      return view
    } catch (e) {
      return empty
    }
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
        const patch = args['config'] as Record<string, Object>
        const store = this.readJsonFile(this.vergeConfigPath)
        if (patch !== undefined) {
          for (const k of Object.keys(patch)) store[k] = patch[k]
        }
        this.writeJsonFile(this.vergeConfigPath, store)
        this.emit('verge://refresh-verge-config', '')
        this.resolve(id, true, null)
        return
      }
      case 'get_profiles': {
        const store = this.readProfilesStore()
        const cur = store['current']
        const current = typeof cur === 'string' && cur.length > 0 ? cur : null
        const view: ProfilesView = { current, items: this.items(store) }
        this.resolve(id, true, view)
        return
      }
      case 'patch_profiles_config': {
        const profiles = args['profiles'] as Record<string, Object>
        if (profiles !== undefined) this.saveProfilesStore(profiles)
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
          this.items(store).push(item)
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
        const rc = bridge.subscriptionFetch(url, outPath)
        if (rc !== 0) {
          this.resolve(id, false, `import_profile: fetch failed rc=${rc}`)
          return
        }
        const store = this.readProfilesStore()
        const item: ProfileItemView = {
          uid,
          type: 'remote',
          name: this.urlName(url),
          url,
          updated: Math.floor(Date.now() / 1000),
        }
        this.items(store).push(item)
        this.saveProfilesStore(store)
        this.emit('verge://refresh-profiles', '')
        this.resolve(id, true, null)
        return
      }
      case 'update_profile': {
        const uid = this.str(args, 'index', '')
        const item = this.findItem(this.readProfilesStore(), uid)
        if (item === null || typeof item['url'] !== 'string') {
          this.resolve(id, false, 'update_profile: profile not found')
          return
        }
        const rc = bridge.subscriptionFetch(item['url'] as string, this.profilePath(uid))
        if (rc !== 0) {
          this.resolve(id, false, `update_profile: fetch failed rc=${rc}`)
          return
        }
        item['updated'] = Math.floor(Date.now() / 1000)
        this.saveProfilesStore(this.readProfilesStore())
        this.emit('verge://refresh-profiles', '')
        this.resolve(id, true, null)
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
      const u = url.replace(/\/+$/, '')
      const last = u.split('/').pop()
      return last !== undefined && last.length > 0 ? last : url
    } catch (e) {
      return url
    }
  }
}
