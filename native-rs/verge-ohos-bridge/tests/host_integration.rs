//! Host integration test: config generation -> spawn a real mihomo -> REST
//! health check -> REST GET -> stop. Requires:
//!   VERGE_TEST_CORE_BIN  path to a mihomo binary for the HOST platform
//! Skipped silently otherwise (CI: build it with scripts/build-core.sh).

use verge_ohos_bridge::{config, core};

#[test]
fn core_lifecycle_end_to_end() {
    let Ok(bin) = std::env::var("VERGE_TEST_CORE_BIN") else {
        eprintln!("VERGE_TEST_CORE_BIN not set; skipping host core test");
        return;
    };
    if !std::path::Path::new(&bin).exists() {
        eprintln!("core binary missing at {bin}; skipping");
        return;
    }

    let dir = std::env::temp_dir().join(format!("verge-ohos-test-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();

    // pick a free port for external-controller
    let port = {
        let l = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        l.local_addr().unwrap().port()
    };

    // minimal profile; profile overrides template (incl. controller port)
    let profile_path = dir.join("profile.yaml");
    std::fs::write(
        &profile_path,
        format!("proxies: []\nrules: []\nexternal-controller: 127.0.0.1:{port}\n"),
    )
    .unwrap();
    let runtime_path = dir.join("runtime.yaml");

    assert_eq!(config::generate_to_file(
        profile_path.to_str().unwrap(),
        runtime_path.to_str().unwrap()
    ), Ok(()));

    let runtime = std::fs::read_to_string(&runtime_path).unwrap();
    assert!(runtime.contains(&format!("external-controller: 127.0.0.1:{port}")));

    let pid = core::start(core::CoreStart {
        binary_path: &bin,
        data_dir: dir.to_str().unwrap(),
        runtime_config_path: runtime_path.to_str().unwrap(),
    })
    .expect("spawn mihomo");
    assert!(pid > 0);
    assert_eq!(core::status().unwrap(), 1);

    let version = core::wait_ready(15_000).expect("core ready");
    assert!(version.contains("version"), "unexpected /version body: {version}");

    let proxies = core::rest_get("/proxies").expect("GET /proxies");
    assert!(proxies.contains("GLOBAL") || proxies.contains("proxies"), "unexpected body");

    let stopped = core::stop().unwrap();
    assert_eq!(stopped, Some(pid));
    assert_eq!(core::status().unwrap(), 0);

    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn config_abi_roundtrip() {
    let dir = std::env::temp_dir().join(format!("verge-ohos-abi-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let profile = dir.join("p.yaml");
    let runtime = dir.join("r.yaml");
    std::fs::write(&profile, b"mode: direct\n").unwrap();
    let c = |s: &std::path::PathBuf| {
        std::ffi::CString::new(s.to_str().unwrap()).unwrap()
    };
    let rc = unsafe {
        verge_ohos_bridge::verge_config_generate(c(&profile).as_ptr(), c(&runtime).as_ptr())
    };
    assert_eq!(rc, 0);
    let out = std::fs::read_to_string(&runtime).unwrap();
    assert!(out.contains("mode: direct"));
    assert!(out.contains("mixed-port: 7897"));
    let _ = std::fs::remove_dir_all(&dir);
}
