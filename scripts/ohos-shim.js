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
      }, slow ? 120000 : 20000)
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
