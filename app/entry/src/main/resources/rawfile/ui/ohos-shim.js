/**
 * ohos-shim.js — Tauri v2 → ArkWeb/NAPI bridge shim.
 *
 * Loaded as a classic script BEFORE the Vite module bundle so that
 * `window.__TAURI_INTERNALS__` / `window.__TAURI_EVENT_PLUGIN_INTERNALS__`
 * exist before @tauri-apps/api imports run.
 *
 * invoke() contract (Tauri v2):
 *   window.__TAURI_INTERNALS__.invoke(cmd, args, options) -> Promise
 * Event contract:
 *   listen()  -> invoke('plugin:event|listen', {event,target,handler}) -> eventId
 *   unlisten() -> invoke('plugin:event|unlisten', {event,eventId}) +
 *                 window.__TAURI_EVENT_PLUGIN_INTERNALS__.unregisterListener(event,eventId)
 *   emit()   -> invoke('plugin:event|emit', {event,payload,target})
 *
 * Async transport to ArkTS: shim stores a pending promise keyed by id, calls
 * window.ohosBridge.dispatch(id, cmd, argsJson) (javaScriptProxy, fire&forget),
 * ArkTS resolves via runJavaScript('window.__ohosResolve(id, ok, payloadJson)').
 * ArkTS -> JS events arrive via runJavaScript('window.__ohosEmit(name, payloadJson)').
 */
(function () {
  'use strict'

  // === Mobile: don't raise the soft keyboard for a field React auto-focuses ===
  // React's autoFocus calls focus() during the first commit, which pops the
  // keyboard over the whole page. Allow focus() only after a real touch.
  ;(function () {
    var interacted = false
    var markInteracted = function () { interacted = true }
    ;['pointerdown', 'touchstart', 'keydown'].forEach(function (evt) {
      window.addEventListener(evt, markInteracted, { capture: true, passive: true })
    })

    var nativeFocus = HTMLElement.prototype.focus
    HTMLElement.prototype.focus = function () {
      var tag = this.tagName
      if (!interacted && (tag === 'INPUT' || tag === 'TEXTAREA')) return
      return nativeFocus.apply(this, arguments)
    }
  })()

  // === Safety: auto-hide loading overlay if React app rendered but didn't hide it ===
  document.addEventListener('DOMContentLoaded', function () {
    setTimeout(function () {
      var overlay = document.getElementById('initial-loading-overlay')
      if (!overlay) return
      var root = document.getElementById('root')
      if (root && root.children.length > 0) {
        overlay.setAttribute('data-hidden', 'true')
      }
    }, 5000)
  })

  // === Mobile layout overrides: adapt the shell and pages for phone screens ===
  function injectMobileStyles() {
    var style = document.createElement('style')
    style.id = 'ohos-mobile-overrides'
    style.textContent = [
      // Mark document as mobile
      '',

      // Hide desktop-only elements: drag bar, window resize handles
      '.layout .layout-content__right .the-bar { display: none !important; }',
      '.window-resize-handles { display: none !important; }',

      // Content area: no top offset needed without the drag bar
      '.layout .layout-content__right .the-content { top: 0 !important; right: 0 !important; }',

      // Page header: let actions wrap to a second row instead of being cut off
      // (e.g. Connections stats, Proxies mode switch).
      '.base-page > header { flex: 0 0 auto !important; flex-wrap: wrap !important; row-gap: 2px !important; height: auto !important; min-height: 42px !important; padding: 4px 10px !important; }',
      '.base-page > header .MuiTypography-root { font-size: 15px !important; font-weight: 600 !important; }',
      '.base-page .base-container { flex: 1 1 auto !important; min-height: 0 !important; height: auto !important; }',
      '.base-page > header > div { flex-wrap: wrap !important; justify-content: flex-end !important; gap: 4px !important; max-width: 100% !important; }',

      // Tighter content section padding
      '.base-page .base-container > section { padding: 4px 0 !important; }',
      '.base-page .base-container > section .base-content { width: calc(100% - 6px * 2) !important; }',

      // Home page: tighter grid spacing
      '.MuiGrid-container { --Grid-spacing: 4px !important; }',
      '.MuiGrid-item { padding-top: 4px !important; padding-left: 4px !important; }',

      // Home page cards: ensure full-width stacking on narrow screens
      '.MuiGrid-grid-xs-6 { flex-basis: 100% !important; max-width: 100% !important; }',
      '.MuiGrid-grid-md-6 { flex-basis: 100% !important; max-width: 100% !important; }',
      '.MuiGrid-grid-md-12 { flex-basis: 100% !important; max-width: 100% !important; }',

      // Profiles page: smaller min column width for narrow screens
      '[style*="gridTemplateColumns"] { grid-template-columns: repeat(auto-fill, minmax(min(100%, 200px), 1fr)) !important; }',

      // Profiles import row: allow wrapping on narrow screens
      '.MuiStack-root:not(.MuiStack-direction-column) { flex-wrap: wrap !important; gap: 4px !important; }',

      // Profile items: compact card padding
      '.MuiCard-root { padding: 8px !important; }',
      '.MuiCardContent-root { padding: 8px !important; }',

      // Dialogs: use more screen width on mobile
      '.MuiDialog-paper { margin: 8px !important; max-width: calc(100% - 16px) !important; }',
      '.MuiDialog-paperWidthSm { max-width: calc(100% - 16px) !important; }',
      '.MuiDialog-paperWidthMd { max-width: calc(100% - 16px) !important; }',

      // Settings page: make setting items more compact
      '.MuiListItem-root { padding-top: 4px !important; padding-bottom: 4px !important; }',

      // Scrollbar: thinner on mobile
      '::-webkit-scrollbar { width: 3px !important; height: 3px !important; }',

      // Traffic stats: smaller font on mobile
      '.the-traffic { font-size: 11px !important; }',

      // Shell: turn the desktop left rail into a bottom tab bar so the page
      // content gets the full phone width.
      '.layout { height: 100dvh !important; }',
      '.layout .layout-content { flex-direction: column !important; padding-bottom: calc(56px + env(safe-area-inset-bottom, 0px)) !important; }',
      '.layout .layout-content__right { flex: 1 1 auto !important; width: 100% !important; height: 100% !important; }',
      '.layout .layout-content__left { position: fixed !important; left: 0 !important; right: 0 !important; bottom: 0 !important; top: auto !important; z-index: 1300 !important; display: flex !important; flex: 0 0 auto !important; flex-direction: row !important; align-items: center !important; width: 100% !important; min-width: 0 !important; max-width: none !important; height: calc(56px + env(safe-area-inset-bottom, 0px)) !important; padding: 0 0 env(safe-area-inset-bottom, 0px) !important; box-sizing: border-box !important; background: var(--background-color, #f5f5f5) !important; border-right: 0 !important; border-top: 1px solid var(--divider-color, rgba(0,0,0,0.08)) !important; }',
      '.layout .layout-content__left .the-logo, .layout .layout-content__left .the-traffic { display: none !important; }',
      '.layout .layout-content__left .the-menu { display: flex !important; flex: 1 1 auto !important; flex-direction: row !important; align-items: stretch !important; width: 100% !important; height: 100% !important; margin: 0 !important; padding: 0 !important; overflow: hidden !important; }',
      // DragDropProvider may wrap the items in an extra element, so normalise
      // the row for any direct child and for the list items themselves.
      '.layout .layout-content__left .the-menu > * { display: flex !important; flex: 1 1 auto !important; flex-direction: row !important; align-items: stretch !important; width: 100% !important; height: 100% !important; margin: 0 !important; padding: 0 !important; }',
      '.layout .layout-content__left .the-menu li { flex: 1 1 0 !important; min-width: 0 !important; max-width: none !important; padding: 0 !important; margin: 0 !important; }',
      '.layout .layout-content__left .the-menu .MuiListItem-root { max-width: none !important; padding: 0 !important; }',
      '.layout .layout-content__left .the-menu .MuiListItemButton-root { display: flex !important; flex-direction: column !important; align-items: center !important; justify-content: center !important; width: 100% !important; height: 100% !important; min-height: 0 !important; max-width: none !important; margin: 0 !important; padding: 4px 0 !important; border-radius: 0 !important; }',
      '.layout .layout-content__left .the-menu .MuiListItemButton-root.Mui-selected { border-radius: 10px !important; margin: 4px 2px !important; height: auto !important; }',
      '.layout .layout-content__left .the-menu .MuiListItemIcon-root { min-width: 0 !important; margin: 0 !important; }',
      '.layout .layout-content__left .the-menu .MuiListItemText-root { display: none !important; }',
      '.layout .layout-content__left .the-menu svg { width: 24px !important; height: 24px !important; font-size: 24px !important; }',

      // Native text inputs would otherwise zoom/focus behind the keyboard.
      'input, textarea { touch-action: manipulation; }',
    ].join('\n')
    document.head.appendChild(style)
  }
  document.addEventListener('DOMContentLoaded', injectMobileStyles)

  // === Tauri v2 → ArkWeb/NAPI bridge shim ===

  const callbacks = new Map() // transformCallback id -> fn
  const eventListeners = new Map() // event name -> Set<handlerId>
  const pending = new Map() // invoke id -> { resolve, reject }
  let seq = 0

  function transformCallback(callback, once) {
    const id = ++seq
    callbacks.set(id, (rawMessage) => {
      callback(rawMessage)
      if (once) callbacks.delete(id)
    })
    return id
  }

  function unregisterCallback(id) {
    callbacks.delete(id)
  }

  function emitLocal(event, payload) {
    const set = eventListeners.get(event)
    if (!set) return
    for (const handlerId of [...set]) {
      const fn = callbacks.get(handlerId)
      if (fn) fn({ event, payload })
    }
  }

  function invoke(cmd, args = {}, options) {
    // --- event plugin handled entirely on the JS side ---
    if (cmd === 'plugin:event|listen') {
      const { event, handler } = args
      if (!eventListeners.has(event)) eventListeners.set(event, new Set())
      eventListeners.get(event).add(handler)
      return Promise.resolve(handler) // eventId == handler id
    }
    if (cmd === 'plugin:event|unlisten') {
      const { event, eventId } = args
      const set = eventListeners.get(event)
      if (set) set.delete(eventId)
      return Promise.resolve(null)
    }
    if (cmd === 'plugin:event|emit' || cmd === 'plugin:event|emit_to') {
      emitLocal(args.event, args.payload)
      return Promise.resolve(null)
    }

    // --- everything else: forward to ArkTS dispatcher ---
    return new Promise((resolve, reject) => {
      const id = 'r' + ++seq
      const slow = cmd === 'import_profile' || cmd === 'update_profile'
      const timer = setTimeout(() => {
        if (pending.has(id)) {
          pending.delete(id)
          reject(new Error('ohos bridge timeout: ' + cmd))
        }
      }, slow ? 150000 : 20000)
      pending.set(id, {
        resolve: (v) => { clearTimeout(timer); resolve(v) },
        reject: (e) => { clearTimeout(timer); reject(e) },
      })
      try {
        window.ohosBridge.dispatch(id, cmd, JSON.stringify(args ?? {}))
      } catch (e) {
        clearTimeout(timer)
        pending.delete(id)
        reject(e)
      }
    })
  }

  window.__ohosResolve = function (id, ok, payload) {
    const p = pending.get(id)
    if (!p) return
    pending.delete(id)
    if (ok === true || ok === 'true' || ok === 1 || ok === '1') {
      p.resolve(payload === undefined ? null : payload)
    } else {
      p.reject(new Error(typeof payload === 'string' ? payload : JSON.stringify(payload)))
    }
  }

  window.__ohosEmit = function (event, payload) {
    emitLocal(event, payload)
  }

  window.__TAURI_INTERNALS__ = {
    invoke,
    transformCallback,
    unregisterCallback,
    convertFileSrc: () => '',
    metadata: {
      currentWindow: { label: 'main' },
      currentWebview: { label: 'main' },
    },
    plugins: {},
  }

  window.__TAURI_EVENT_PLUGIN_INTERNALS__ = {
    unregisterListener(event, eventId) {
      const set = eventListeners.get(event)
      if (set) set.delete(eventId)
    },
    emit: emitLocal,
  }

  // Debug helpers used by Index.ets console
  window.__ohosPing = function () {
    return window.ohosBridge.ping()
  }
  window.__ohosBridgeVersion = function () {
    return window.ohosBridge.bridgeVersion()
  }

})()
