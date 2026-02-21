pub mod archive;
pub mod packager_common;
pub mod rpm;

use std::path::Path;

use anyhow::Result;
use trolley_config::{Config, Format};

use super::common::BundleManifest;

/// Build all requested formats from the assembled bundle directory.
pub fn build_formats(
    formats: &[Format],
    bundle_dir: &Path,
    dist_dir: &Path,
    config: &Config,
    manifest: &BundleManifest,
) -> Result<()> {
    // Collect formats handled by cargo-packager vs trolley's own builders
    let mut packager_formats: Vec<packager_common::PackagerFormat> = Vec::new();

    for format in formats {
        match format {
            Format::Archive => {
                archive::build(bundle_dir, dist_dir, config, manifest)?;
            }
            Format::Rpm => {
                rpm::build(bundle_dir, dist_dir, config, manifest)?;
            }
            Format::Deb => packager_formats.push(packager_common::PackagerFormat::Deb),
            Format::AppImage => packager_formats.push(packager_common::PackagerFormat::AppImage),
            Format::Pacman => packager_formats.push(packager_common::PackagerFormat::Pacman),
            Format::Nsis => packager_formats.push(packager_common::PackagerFormat::Nsis),
            Format::MacApp => packager_formats.push(packager_common::PackagerFormat::MacApp),
            Format::Dmg => packager_formats.push(packager_common::PackagerFormat::Dmg),
        }
    }

    // Run cargo-packager for all collected formats in one pass
    if !packager_formats.is_empty() {
        packager_common::run_packager(config, bundle_dir, dist_dir, manifest, &packager_formats)?;
    }

    Ok(())
}
