/**
 * VergeVpnAbility.ets — P3 VPN data plane (VpnExtensionAbility).
 *
 * Creates the system TUN, hands its fd to the mihomo sidecar via
 * `tun.file-descriptor` (mihomo listener/sing_tun supports external fds),
 * and supervises the core while the VPN is up.
 *
 * Loop avoidance: `blockedApplications: [own bundle]` keeps every process of
 * this app — including the sidecar core child (same UID) — off the tunnel, so
 * core outbound dials go direct without cross-process socket protection.
 *
 * Process model: the core runs in THIS extension process. The UI process
 * reaches it through the external-controller REST (the Rust bridge's rest_get
 * falls back to the address in the last runtime config). Status is published
 * to `filesDir/verge-vpn-status.txt` and read by the UI dispatcher.
 *
 * Runtime verification requires a real device or a DevEco emulator with the
 * vpndialog component (see handover doc §未验证).
 */
import VpnExtensionAbility from '@ohos.app.ability.VpnExtensionAbility'
import Want from '@ohos.app.ability.Want'
import { fileIo as fs } from '@kit.CoreFileKit'
import connection from '@ohos.net.connection'
import vpnExtension from '@ohos.net.vpnExtension'
import bridge from 'libentry.so'
import { hilog } from '@kit.PerformanceAnalysisKit'

const TAG = 'VergeVpnAbility'
const BUNDLE_NAME = 'io.github.clashverge.harmony'
const IPV4_ADDRESS = '172.19.0.1'
const IPV4_PREFIX = 30
const IPV4_FAMILY = 1
const DNS4 = '172.19.0.2'
const STATUS_FILE = 'verge-vpn-status.txt'
const SUPERVISOR_INTERVAL_MS = 10000

export default class VergeVpnAbility extends VpnExtensionAbility {
  private vpnConnection: vpnExtension.VpnConnection | null = null
  private supervisorToken = 0

  private writeStatus(status: string): void {
    try {
      const path = `${this.context.filesDir}/${STATUS_FILE}`
      const file = fs.openSync(
        path,
        fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC,
      )
      try {
        fs.writeSync(file.fd, status)
      } finally {
        fs.closeSync(file)
      }
    } catch (e) {
      hilog.warn(0x0666, TAG, 'status', 'write failed: %{public}s', JSON.stringify(e))
    }
  }

  private readStatus(): string {
    try {
      const path = `${this.context.filesDir}/${STATUS_FILE}`
      if (!fs.accessSync(path)) return ''
      return fs.readTextSync(path)
    } catch (e) {
      return ''
    }
  }

  private resolveCoreBinPath(): string {
    const candidates: string[] = [
      `${this.context.bundleCodeDir}/libs/arm64/libverge_mihomo.so`,
      `${this.context.bundleCodeDir}/libs/arm64-v8a/libverge_mihomo.so`,
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

  /** Remove a previously appended top-level `tun:` block (end of file). */
  private stripTunBlock(yaml: string): string {
    const lines = yaml.split('\n')
    const out: string[] = []
    let inTun = false
    for (const line of lines) {
      if (/^tun:/.test(line)) {
        inTun = true
        continue
      }
      if (inTun) {
        if (/^\S/.test(line)) inTun = false
        else continue
      }
      out.push(line)
    }
    return out.join('\n')
  }

  private writeText(path: string, text: string): void {
    const file = fs.openSync(
      path,
      fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC,
    )
    try {
      fs.writeSync(file.fd, text)
    } finally {
      fs.closeSync(file)
    }
  }

  private startCoreWithTun(fd: number): number {
    const coreDir = `${this.context.filesDir}/clash`
    const runtimePath = `${coreDir}/runtime.yaml`
    try {
      fs.mkdirSync(coreDir, true)
    } catch (e) {
      // dir exists
    }
    let yaml = ''
    try {
      if (fs.accessSync(runtimePath)) yaml = fs.readTextSync(runtimePath)
    } catch (e) {
      // regenerate below
    }
    if (yaml.trim().length === 0) {
      yaml = [
        'mixed-port: 7890',
        'allow-lan: false',
        'mode: rule',
        'log-level: info',
        'external-controller: 127.0.0.1:9090',
      ].join('\n')
    }
    yaml = this.stripTunBlock(yaml)
    yaml += [
      '',
      'tun:',
      '  enable: true',
      `  file-descriptor: ${fd}`,
      '  stack: system',
      '  auto-route: false',
    ].join('\n')
    this.writeText(runtimePath, yaml)
    return bridge.coreStart(this.resolveCoreBinPath(), coreDir, runtimePath)
  }

  async onCreate(want: Want): Promise<void> {
    this.vpnConnection = vpnExtension.createVpnConnection(this.context)
    const supervisorToken = ++this.supervisorToken
    this.writeStatus('starting')
    try {
      const addresses: Array<connection.LinkAddress> = [
        {
          address: { address: IPV4_ADDRESS, family: IPV4_FAMILY },
          prefixLength: IPV4_PREFIX,
        },
      ]
      const routes: Array<connection.RouteInfo> = [
        {
          interface: '',
          destination: {
            address: { address: '0.0.0.0', family: IPV4_FAMILY },
            prefixLength: 0,
          },
          gateway: { address: '', family: IPV4_FAMILY },
          hasGateway: false,
          isDefaultRoute: true,
        },
      ]
      const fd = await this.vpnConnection.create({
        addresses,
        routes,
        dnsAddresses: [DNS4],
        mtu: 9000,
        isIPv4Accepted: true,
        isIPv6Accepted: false,
        isInternal: false,
        isBlocking: false,
        blockedApplications: [BUNDLE_NAME],
      })
      const pid = this.startCoreWithTun(fd)
      if (pid <= 0) {
        const msg = `coreStart failed rc=${pid}`
        this.writeStatus(`failed:${msg}`)
        try {
          await this.vpnConnection.destroy()
        } catch (e) {
          // connection already torn down
        }
        this.vpnConnection = null
        throw new Error(msg)
      }
      this.writeStatus('started')
      hilog.info(0x0666, TAG, 'vpn', 'started fd=%{public}d pid=%{public}d', fd, pid)

      // Supervisor: auto-restart the core if it dies while the VPN is up.
      const self = this
      const interval = setInterval(() => {
        if (self.supervisorToken !== supervisorToken) {
          clearInterval(interval)
          return
        }
        if (self.readStatus() !== 'started') {
          clearInterval(interval)
          return
        }
        try {
          if (bridge.coreStatus() <= 0) {
            hilog.warn(0x0666, TAG, 'vpn', 'core died; restarting with fd=%{public}d', fd)
            const rp = self.startCoreWithTun(fd)
            if (rp <= 0) self.writeStatus(`failed:restart rc=${rp}`)
          }
        } catch (e) {
          hilog.warn(0x0666, TAG, 'vpn', 'supervisor error: %{public}s', JSON.stringify(e))
        }
      }, SUPERVISOR_INTERVAL_MS)
    } catch (e) {
      const msg = JSON.stringify(e)
      this.writeStatus(`failed:${msg}`)
      hilog.error(0x0666, TAG, 'vpn', 'onCreate failed: %{public}s', msg)
      throw new Error(msg)
    }
  }

  async onDestroy(): Promise<void> {
    this.supervisorToken += 1
    const errors: string[] = []
    try {
      bridge.coreStop()
    } catch (e) {
      errors.push(`coreStop: ${JSON.stringify(e)}`)
    }
    try {
      await this.vpnConnection?.destroy()
    } catch (e) {
      errors.push(`destroy: ${JSON.stringify(e)}`)
    }
    this.vpnConnection = null
    this.writeStatus(errors.length > 0 ? `failed:${errors.join(' | ')}` : 'stopped')
  }
}
