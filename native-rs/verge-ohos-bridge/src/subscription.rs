//! Subscription fetching (profile download). Pure-Rust TLS via rustls, so the
//! same code compiles for the OHOS target without OpenSSL. On HarmonyOS the
//! system cert store is not in webpki-roots, so callers on device should pass
/// a PEM bundle path once cert distribution is settled (P3); host tests use
/// webpki-roots.

use std::io::Read;

/// Fetch a URL and return the body (max 10 MiB).
pub fn fetch(url: &str) -> Result<Vec<u8>, String> {
    let agent = ureq::AgentBuilder::new()
        .timeout_connect(std::time::Duration::from_secs(10))
        .timeout(std::time::Duration::from_secs(30))
        .build();
    let resp = agent
        .get(url)
        .set("User-Agent", "clash-verge-harmony/0.1")
        .call()
        .map_err(|e| format!("{url}: {e}"))?;
    let mut buf = Vec::new();
    let mut owned = resp.into_reader();
    let reader: &mut dyn std::io::Read = &mut owned;
    reader
        .take(10 << 20)
        .read_to_end(&mut buf)
        .map_err(|e| format!("read body: {e}"))?;
    Ok(buf)
}

/// Fetch a subscription and persist it as a profile file.
pub fn fetch_to_file(url: &str, out_path: &str) -> Result<usize, String> {
    let body = fetch(url)?;
    if let Some(parent) = std::path::Path::new(out_path).parent() {
        std::fs::create_dir_all(parent).map_err(|e| format!("mkdir {parent:?}: {e}"))?;
    }
    std::fs::write(out_path, &body).map_err(|e| format!("write {out_path}: {e}"))?;
    Ok(body.len())
}

#[cfg(test)]
mod tests {
    #[test]
    #[ignore = "network; run with VERGE_TEST_URL set"]
    fn fetches_https_body() {
        let url = std::env::var("VERGE_TEST_URL").unwrap();
        let body = super::fetch(&url).unwrap();
        assert!(!body.is_empty());
    }
}
