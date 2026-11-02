//! mihomo sidecar management, mirroring Verge's core-manager process model:
//! spawn the bundled executable with `-d <data_dir> -f <config>`, health-check
//! the external-controller REST API, stop on demand.

use serde_yaml::Mapping;
use std::io::Read;
use std::process::{Child, Command, Stdio};
use std::sync::Mutex;
use std::time::{Duration, Instant};

pub struct CoreHandle {
    child: Child,
    controller: String,
    secret: String,
}

static CORE: Mutex<Option<CoreHandle>> = Mutex::new(None);

pub struct CoreStart<'a> {
    pub binary_path: &'a str,
    pub data_dir: &'a str,
    pub runtime_config_path: &'a str,
}

/// Spawn mihomo as a sidecar. Fails if one is already running.
pub fn start(spec: CoreStart) -> Result<u32, String> {
    let mut guard = CORE.lock().map_err(|e| e.to_string())?;
    if guard.is_some() {
        return Err("core already running".into());
    }

    let yaml = std::fs::read_to_string(spec.runtime_config_path)
        .map_err(|e| format!("read runtime config: {e}"))?;
    let map: Mapping = serde_yaml::from_str(&yaml)
        .map_err(|e| format!("parse runtime config: {e}"))?;
    let controller = super::config::external_controller(&map)
        .ok_or("runtime config has no external-controller")?;
    let secret = super::config::secret(&map).unwrap_or_default();

    std::fs::create_dir_all(spec.data_dir).map_err(|e| format!("create data dir: {e}"))?;
    let child = Command::new(spec.binary_path)
        .arg("-d")
        .arg(spec.data_dir)
        .arg("-f")
        .arg(spec.runtime_config_path)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|e| format!("spawn {}: {e}", spec.binary_path))?;
    let pid = child.id();

    *guard = Some(CoreHandle {
        child,
        controller: format!("http://{controller}"),
        secret,
    });
    Ok(pid)
}

/// Kill the running core and reap it. Returns stopped pid.
pub fn stop() -> Result<Option<u32>, String> {
    let mut guard = CORE.lock().map_err(|e| e.to_string())?;
    match guard.take() {
        Some(mut h) => {
            let pid = h.child.id();
            let _ = h.child.kill();
            let _ = h.child.wait();
            Ok(Some(pid))
        }
        None => Ok(None),
    }
}

/// 0 = not running, 1 = running (and process alive).
pub fn status() -> Result<i32, String> {
    let mut guard = CORE.lock().map_err(|e| e.to_string())?;
    match guard.as_mut() {
        None => Ok(0),
        Some(h) => match h.child.try_wait() {
            Ok(Some(_)) => {
                *guard = None;
                Ok(0)
            }
            Ok(None) => Ok(1),
            Err(e) => Err(e.to_string()),
        },
    }
}

fn get_json(base: &str, secret: &str, path: &str) -> Result<String, String> {
    let resp = ureq::get(&format!("{base}{path}"))
        .timeout(Duration::from_secs(2))
        .set("Authorization", &format!("Bearer {secret}"))
        .call()
        .map_err(|e| e.to_string())?;
    let mut body = String::new();
    let mut owned = resp.into_reader();
    let reader: &mut dyn std::io::Read = &mut owned;
    reader
        .take(1 << 20)
        .read_to_string(&mut body)
        .map_err(|e| e.to_string())?;
    Ok(body)
}

/// Poll `{external-controller}/version` until mihomo answers, up to `timeout_ms`.
pub fn wait_ready(timeout_ms: u64) -> Result<String, String> {
    let deadline = Instant::now() + Duration::from_millis(timeout_ms);
    loop {
        {
            let guard = CORE.lock().map_err(|e| e.to_string())?;
            match guard.as_ref() {
                None => return Err("core not started".into()),
                Some(h) => {
                    if let Ok(body) = get_json(&h.controller, &h.secret, "/version") {
                        return Ok(body);
                    }
                }
            }
        }
        if Instant::now() > deadline {
            return Err("core did not become ready in time".into());
        }
        std::thread::sleep(Duration::from_millis(250));
    }
}

/// GET an arbitrary core REST path with auth (e.g. `/proxies`, `/configs`).
pub fn rest_get(path: &str) -> Result<String, String> {
    let guard = CORE.lock().map_err(|e| e.to_string())?;
    match guard.as_ref() {
        None => Err("core not started".into()),
        Some(h) => get_json(&h.controller, &h.secret, path),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rest_errors_when_not_started() {
        let _ = stop();
        assert!(rest_get("/version").is_err());
        assert!(wait_ready(1).is_err());
    }
}
