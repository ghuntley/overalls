use std::{env, io, path::PathBuf, process::Command};

fn required_env(name: &str, purpose: &str) -> io::Result<PathBuf> {
    env::var_os(name)
        .map(PathBuf::from)
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, purpose.to_owned()))
}

fn main() -> io::Result<()> {
    let root = required_env("CARGO_MANIFEST_DIR", "manifest directory")?;
    let script = root.join("../../localization/generate_catalogs.py");
    let source = root.join("../../localization/catalogs");
    let output = required_env("OUT_DIR", "OUT_DIR")?.join("mila-locales");
    let status = Command::new("python3")
        .arg(script)
        .arg("--source")
        .arg(source)
        .arg("--output")
        .arg(&output)
        .status()
        .map_err(|error| {
            io::Error::new(
                error.kind(),
                format!("run Mila localization generator: {error}"),
            )
        })?;
    assert!(status.success(), "Mila localization generation failed");
    println!("cargo:rustc-env=MILA_BUILT_LOCALE_DIR={}", output.display());
    println!("cargo:rerun-if-changed=../../localization/generate_catalogs.py");
    println!("cargo:rerun-if-changed=../../localization/catalogs");
    Ok(())
}
