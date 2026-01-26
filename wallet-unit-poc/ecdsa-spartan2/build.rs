use std::path::Path;

fn main() {
    // Construct absolute path to circuits using CARGO_MANIFEST_DIR
    // This ensures the path resolves correctly regardless of working directory
    let manifest_dir = std::env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR not set");
    let circuits_dir = std::path::PathBuf::from(&manifest_dir)
        .parent() // Go up from ecdsa-spartan2/ to wallet-unit-poc/
        .expect("Failed to get parent directory")
        .join("circom/build/cpp");
    let circuits_path = circuits_dir.to_str().unwrap();

    // Check for pre-built witnesscalc cache from build_pod.sh
    if let Ok(witnesscalc_cache) = std::env::var("WITNESSCALC_PREBUILD_CACHE") {
        let out_dir = std::env::var("OUT_DIR").expect("OUT_DIR not set");
        let target = std::env::var("TARGET").unwrap_or_default();

        // Only apply for iOS targets
        match target.as_str() {
            "aarch64-apple-ios-sim" | "aarch64-apple-ios" | "x86_64-apple-ios" => {
                let cache_src = Path::new(&witnesscalc_cache);
                let target_witnesscalc = Path::new(&out_dir).join("witnesscalc");

                // Symlink entire witnesscalc directory if cache exists and target doesn't
                if cache_src.exists() && !target_witnesscalc.exists() {
                    #[cfg(unix)]
                    {
                        println!(
                            "cargo:warning=Using cached witnesscalc from: {}",
                            cache_src.display()
                        );
                        std::os::unix::fs::symlink(&cache_src, &target_witnesscalc).ok();
                    }
                }
            }
            _ => {}
        }
    }

    witnesscalc_adapter::build_and_link(circuits_path);
}
