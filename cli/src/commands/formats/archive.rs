use std::fs;
use std::path::Path;

use anyhow::{Context, Result};
use flate2::Compression;
use flate2::write::GzEncoder;
use trolley_config::Config;

use super::super::common::BundleManifest;

pub fn build(
    bundle_dir: &Path,
    dist_dir: &Path,
    config: &Config,
    manifest: &BundleManifest,
) -> Result<()> {
    let filename = format!(
        "{}-{}-{}.tar.gz",
        config.app.slug, config.app.version, manifest.target
    );
    let output_path = dist_dir.join(&filename);

    let file = fs::File::create(&output_path)
        .with_context(|| format!("creating {}", output_path.display()))?;
    let gz = GzEncoder::new(file, Compression::default());
    let mut tar_builder = tar::Builder::new(gz);

    // Archive bundle contents under a top-level directory named after the slug
    tar_builder
        .append_dir_all(&config.app.slug, bundle_dir)
        .context("adding bundle to tar.gz archive")?;

    let gz = tar_builder.into_inner().context("finishing tar archive")?;
    gz.finish().context("finishing gzip compression")?;

    println!("  {filename}  (tar.gz archive)");
    Ok(())
}
