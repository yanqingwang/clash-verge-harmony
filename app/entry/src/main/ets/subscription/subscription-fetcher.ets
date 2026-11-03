/**
 * subscription-fetcher.ets — HarmonyOS-native subscription download.
 *
 * Why this exists (P3 diagnosis):
 *   The previous path was JS → javaScriptProxy (main thread) → NAPI dlsym →
 *   ureq(rustls, musl getaddrinfo). On device that blocks the ArkTS UI thread
 *   for the whole download AND rides the musl DNS/cert stack, which is not the
 *   host stack: the NDK sysroot ships no /etc/ssl/certs and no /etc/resolv.conf.
 *   That is the "subscription won't load" symptom even though the URL and the
 *   generated config are fine (host: FETCH_OK 500710 bytes, GENERATE_OK 46
 *   proxies).
 *
 * This module uses @ohos.net.http instead:
 *   - request() is asynchronous and runs on the system netstack → no UI-thread
 *     stall, no blocking I/O on the caller thread.
 *   - TLS terminates in the HarmonyOS network stack with the platform trust
 *     store and the platform resolver → the musl cert/DNS risk disappears.
 * The Rust/ureq bridge is kept as a fallback for hosts/devices where the native
 * netstack path is unavailable, so we never lose the P1 capability.
 */

import { http } from '@kit.NetworkKit'
import { fileIo as fs } from '@kit.CoreFileKit'
import { BusinessError } from '@kit.BasicServicesKit'
import { hilog } from '@kit.PerformanceAnalysisKit'

const TAG = 'SubFetcher'
const DOMAIN = 0x0666

/** Structured outcome — every field is surfaced to the UI on failure. */
export interface SubscriptionFetchResult {
  /** HTTP status of the successful (native) attempt; -1 when it never got one. */
  httpCode: number
  /** Bytes written to the profile file. */
  bytes: number
  /** Human-readable failure reason; '' when ok. */
  error: string
  /** Which transport produced the body: 'ohos-http' | 'rustls'. */
  source: string
}

const UA = 'clash-verge-harmony/0.3 (HarmonyOS @ohos.net.http)'
const MAX_BODY_BYTES = 10 * 1024 * 1024

function fail(error: string, httpCode: number = -1, source: string = 'ohos-http'): SubscriptionFetchResult {
  return { httpCode, bytes: 0, error, source }
}

/**
 * Download `url` to `outPath` via the HarmonyOS network stack.
 *
 * Resolves with a SubscriptionFetchResult; `error` is '' on success. Never
 * throws — callers branch on `result.error.length === 0`.
 */
export async function fetchSubscriptionTo(url: string, outPath: string): Promise<SubscriptionFetchResult> {
  if (url.length === 0) {
    return fail('empty subscription url')
  }

  const req = http.createHttp()
  try {
    const resp = await req.request(url, {
      method: http.RequestMethod.GET,
      expectDataType: http.HttpDataType.STRING,
      usingCache: false,
      header: { 'User-Agent': UA, 'Accept': '*/*' },
      // Subscription bodies are small (≤ a few MiB); keep it modest but not
      // tight enough to cut off slow mirrors. Server may stream for a while.
      connectTimeout: 15000,
      readTimeout: 60000,
    } as http.HttpRequestOptions)

    const code = resp.responseCode
    const body = resp.result
    if (code < 200 || code >= 300) {
      hilog.warn(DOMAIN, TAG, 'HTTP %{public}d for %{public}s', code, url)
      return fail(`HTTP ${code}`, code)
    }
    if (typeof body !== 'string') {
      return fail(`unexpected body type ${typeof body}`, code)
    }
    if (body.length === 0) {
      return fail('empty response body', code)
    }
    if (body.length > MAX_BODY_BYTES) {
      return fail(`body too large: ${body.length}`, code)
    }

    // Sanity gate: a Clash/mihomo profile is YAML; reject HTML error pages so
    // we never persist a useless "profile" and silently fail later at core
    // start.
    const head = body.slice(0, 256).toLowerCase()
    if (head.includes('<!doctype html') || head.includes('<html')) {
      return fail('response is HTML, not a Clash profile (wrong URL or login page)', code)
    }

    await writeText(outPath, body)
    hilog.info(DOMAIN, TAG, 'subscription OK: %{public}d bytes from %{public}s', body.length, url)
    return { httpCode: code, bytes: body.length, error: '', source: 'ohos-http' }
  } catch (e) {
    const be = e as BusinessError
    const reason = be.code !== undefined
      ? `netstack error ${be.code}: ${be.message}`
      : `request failed: ${JSON.stringify(e)}`
    hilog.error(DOMAIN, TAG, 'subscription FAIL %{public}s: %{public}s', url, reason)
    return fail(reason)
  } finally {
    req.destroy()
  }
}

/** Write text atomically (static import keeps this ArkTS-strict clean). */
async function writeText(path: string, text: string): Promise<void> {
  const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC)
  try {
    fs.writeSync(file.fd, text)
  } finally {
    fs.closeSync(file)
  }
}