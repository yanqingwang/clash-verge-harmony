//! Runtime config generation, mirroring `src-tauri/src/config/clash.rs`:
//! Verge template defaults fill keys missing from the user profile; profile
//! values win; an empty `secret` is replaced with a placeholder.

use serde_yaml::{Mapping, Value};

/// Defaults ported from `clash.rs::template()` + `src-tauri/src/constants.rs`
/// (network::ports). OHOS-relevant subset; tun stays disabled here — TUN on
/// HarmonyOS is owned by VpnExtensionAbility (P3), not by mihomo directly.
pub fn template() -> Mapping {
    let mut map = Mapping::new();
    map.insert("mixed-port".into(), 7897.into());
    map.insert("socks-port".into(), 7898.into());
    map.insert("port".into(), 7899.into());
    map.insert("log-level".into(), "info".into());
    map.insert("allow-lan".into(), false.into());
    map.insert("ipv6".into(), true.into());
    map.insert("mode".into(), "rule".into());
    map.insert(
        "external-controller".into(),
        "127.0.0.1:9097".into(),
    );
    let mut tun = Mapping::new();
    tun.insert("enable".into(), false.into());
    tun.insert("stack".into(), "gvisor".into());
    tun.insert("auto-route".into(), true.into());
    tun.insert("strict-route".into(), false.into());
    map.insert("tun".into(), tun.into());
    map.insert("secret".into(), "set-your-secret".into());
    map.insert("unified-delay".into(), true.into());
    map
}

/// Generate the runtime config: profile YAML merged over the Verge template.
///
/// Semantics from `clash.rs::load()` / `guard()`: every template key missing
/// from the profile is inserted (profile wins); an empty `secret` becomes
/// `set-your-secret`.
pub fn generate(profile_yaml: &str) -> Result<String, String> {
    let profile: Value = serde_yaml::from_str(profile_yaml)
        .map_err(|e| format!("invalid profile yaml: {e}"))?;
    let mut map = match profile {
        Value::Mapping(m) => m,
        _ => return Err("profile root must be a yaml mapping".into()),
    };

    for (k, v) in template() {
        map.entry(k).or_insert(v);
    }

    if let Some(Value::String(s)) = map.get_mut("secret") {
        if s.is_empty() {
            *s = "set-your-secret".into();
        }
    }

    serde_yaml::to_string(&Value::Mapping(map)).map_err(|e| format!("serialize failed: {e}"))
}

/// Convenience: read profile file, generate runtime config, write it out.
pub fn generate_to_file(profile_path: &str, runtime_path: &str) -> Result<(), String> {
    let yaml = std::fs::read_to_string(profile_path)
        .map_err(|e| format!("read {profile_path}: {e}"))?;
    let out = generate(&yaml)?;
    std::fs::write(runtime_path, out).map_err(|e| format!("write {runtime_path}: {e}"))
}

/// Extract `external-controller` (`host:port`) from a generated config map.
pub fn external_controller(map: &Mapping) -> Option<String> {
    match map.get(Value::String("external-controller".into())) {
        Some(Value::String(s)) => Some(s.clone()),
        _ => None,
    }
}

/// Extract `secret` from a generated config map.
pub fn secret(map: &Mapping) -> Option<String> {
    match map.get(Value::String("secret".into())) {
        Some(Value::String(s)) => Some(s.clone()),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn profile_wins_template_fills() {
        let profile = "mixed-port: 17890\nmode: global\n";
        let out = generate(profile).unwrap();
        let m: Mapping = serde_yaml::from_str(&out).unwrap();
        assert_eq!(m.get("mixed-port"), Some(&Value::from(17890))); // profile wins
        assert_eq!(m.get("mode"), Some(&Value::from("global")));
        assert_eq!(m.get("socks-port"), Some(&Value::from(7898))); // template fills
        assert_eq!(m.get("external-controller"), Some(&Value::from("127.0.0.1:9097")));
    }

    #[test]
    fn empty_secret_gets_placeholder() {
        let out = generate("secret: \"\"\n").unwrap();
        let m: Mapping = serde_yaml::from_str(&out).unwrap();
        assert_eq!(m.get("secret"), Some(&Value::from("set-your-secret")));
    }

    #[test]
    fn invalid_yaml_is_an_error() {
        assert!(generate("a: [unclosed").is_err());
        assert!(generate("- just\n- a\n- list\n").is_err());
    }
}
