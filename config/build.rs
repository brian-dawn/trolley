fn main() {
    let version = std::fs::read_to_string("../VERSION")
        .expect("failed to read VERSION file")
        .trim()
        .to_string();

    let cargo_version = env!("CARGO_PKG_VERSION");
    assert_eq!(
        version, cargo_version,
        "VERSION file ({version}) does not match config/Cargo.toml version ({cargo_version})"
    );

    println!("cargo:rustc-env=TROLLEY_VERSION={version}");
    println!("cargo:rerun-if-changed=../VERSION");

    let crate_dir = std::env::var("CARGO_MANIFEST_DIR").unwrap();
    let config = cbindgen::Config::from_file(format!("{crate_dir}/cbindgen.toml"))
        .expect("failed to read cbindgen.toml");
    cbindgen::Builder::new()
        .with_crate(&crate_dir)
        .with_config(config)
        .generate()
        .expect("failed to generate C bindings")
        .write_to_file(format!("{crate_dir}/include/trolley.h"));

    println!("cargo:rerun-if-changed=src/lib.rs");
}
