fn main() {
    let version = std::fs::read_to_string("../VERSION")
        .expect("failed to read VERSION file")
        .trim()
        .to_string();

    let cargo_version = env!("CARGO_PKG_VERSION");
    assert_eq!(
        version, cargo_version,
        "VERSION file ({version}) does not match cli/Cargo.toml version ({cargo_version})"
    );

    println!("cargo:rustc-env=TROLLEY_VERSION={version}");
    println!("cargo:rerun-if-changed=../VERSION");

    let runtime_source = match std::env::var("TROLLEY_RUNTIME_SOURCE") {
        Ok(val) => val,
        Err(_) => {
            let profile = std::env::var("PROFILE").unwrap_or_default();
            if profile == "release" {
                panic!("TROLLEY_RUNTIME_SOURCE must be set for release builds");
            }
            let manifest_dir = std::env::var("CARGO_MANIFEST_DIR").unwrap();
            let repo_root = std::path::Path::new(&manifest_dir).parent().unwrap();
            repo_root
                .join("runtime/zig-out-debug/bin/trolley")
                .to_str()
                .unwrap()
                .to_string()
        }
    };
    println!("cargo:rustc-env=TROLLEY_RUNTIME_SOURCE={runtime_source}");
    println!("cargo:rerun-if-env-changed=TROLLEY_RUNTIME_SOURCE");
}
