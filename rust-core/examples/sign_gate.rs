//! Signs one bundle with a certificate and profiles made in the test, then
//! audits the result. scripts/sign-gate.sh builds the inputs with Apple's own
//! tools and checks the output with `codesign`; this binary is the library
//! half: it runs the signer the app runs, through the vendored `isideload`
//! path (profile per bundle, empty entitlements for libraries), with no Apple
//! account and no network.
//!
//!     sign_gate <app.app> <identity.p12-password> <key.der> <cert.der> <main.mobileprovision>
//!               <bundle-id>=<profile> [<bundle-id>=<profile> ...] <out.report>
//!
//! The report is one `key=value` line per fact the script asserts on; the
//! script does the asserting, so a failure names the bundle and the field.

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

use apple_codesign_quick::{
    BundleSigningSettings, ProvisioningProfile, RustCryptoCmsSigner, sign_bundle,
};

fn main() {
    if let Err(e) = run() {
        eprintln!("sign_gate: {e}");
        std::process::exit(1);
    }
}

fn read_der(path: &str) -> Vec<u8> {
    fs::read(path).unwrap_or_else(|e| panic!("{path}: {e}"))
}

fn run() -> Result<(), String> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.len() < 3 {
        return Err("usage: sign_gate <app.app> <key.der> <cert.der> <chain.der|-> <main.mobileprovision> [<bundle-id>=<profile> ...]".into());
    }
    let app = PathBuf::from(&args[0]);
    let key = read_der(&args[1]);
    let cert = read_der(&args[2]);
    let chain = if args[3] == "-" { Vec::new() } else { read_der(&args[3]) };
    let main_profile_der = fs::read(&args[4]).map_err(|e| format!("{}: {e}", args[4]))?;
    let profiles_from = 5;

    let chain_vecs: Vec<Vec<u8>> = if chain.is_empty() { Vec::new() } else { vec![chain] };
    let signer = RustCryptoCmsSigner::from_der(&key, &cert, chain_vecs.iter().map(Vec::as_slice))
        .map_err(|e| format!("signer: {e}"))?;

    let main_profile = ProvisioningProfile::parse(&main_profile_der)
        .map_err(|e| format!("main profile: {e}"))?;
    let team_id = main_profile.team_id().to_string();

    let mut settings = BundleSigningSettings::new(
        team_id.clone(),
        main_profile.entitlements().clone(),
        Some(&signer),
    );
    let mut profiles: BTreeMap<String, Vec<u8>> = BTreeMap::new();
    for pair in &args[profiles_from..] {
        let (id, path) = pair
            .split_once('=')
            .ok_or_else(|| format!("expected <bundle-id>=<profile>, got {pair}"))?;
        if id == "app" {
            continue;
        }
        let der = fs::read(path).map_err(|e| format!("{path}: {e}"))?;
        let parsed = ProvisioningProfile::parse(&der).map_err(|e| format!("{path}: {e}"))?;
        settings
            .entitlements_by_bundle_id
            .insert(id.to_string(), parsed.entitlements().clone());
        profiles.insert(id.to_string(), der);
    }
    for (id, der) in &profiles {
        settings
            .embedded_mobileprovisions_by_bundle_id
            .insert(id.clone(), der.as_slice());
    }
    settings.embedded_mobileprovision = Some(&main_profile_der);

    sign_bundle(&app, &settings).map_err(|e| format!("sign_bundle: {e}"))?;

    // What it produced, for the script to assert on: the profile each bundle
    // embeds (by SHA-256) and whether a signature directory was written.
    let mut out = String::new();
    out.push_str(&format!("team_id={team_id}\n"));
    out.push_str(&format!(
        "main_sha256={}\n",
        sha256_hex(&main_profile_der)
    ));
    for (id, der) in &profiles {
        out.push_str(&format!("profile_sha256[{id}]={}\n", sha256_hex(der)));
    }
    {
        let app_ref: &Path = &app;
        walk(app_ref, app_ref, &mut out);
    }
    print!("{out}");
    Ok(())
}

fn walk(root: &Path, dir: &Path, out: &mut String) {
    let Ok(entries) = fs::read_dir(dir) else { return };
    for entry in entries.flatten() {
        let path = entry.path();
        let name = entry.file_name().to_string_lossy().to_string();
        if path.is_dir() {
            if name.ends_with(".app") || name.ends_with(".appex") || name.ends_with(".framework") {
                let has_sig = path.join("_CodeSignature").join("CodeResources").is_file();
                let profile = fs::read(path.join("embedded.mobileprovision")).ok();
                let id = plist_bundle_id(&path).unwrap_or_default();
                out.push_str(&format!("bundle[{}]={id}\n", rel(root, &path)));
                out.push_str(&format!(
                    "codesigned[{}]={}\n",
                    rel(root, &path),
                    has_sig
                ));
                match profile {
                    Some(der) => out.push_str(&format!(
                        "embedded_sha256[{}]={}\n",
                        rel(root, &path),
                        sha256_hex(&der)
                    )),
                    None => out.push_str(&format!("embedded_sha256[{}]=none\n", rel(root, &path))),
                }
            }
            walk(root, &path, out);
        }
    }
}

fn rel(root: &Path, path: &Path) -> String {
    path.strip_prefix(root)
        .map(|p| p.to_string_lossy().to_string())
        .unwrap_or_else(|_| path.to_string_lossy().to_string())
}

fn plist_bundle_id(bundle: &Path) -> Option<String> {
    let data = fs::read(bundle.join("Info.plist")).ok()?;
    let value: plist::Value = plist::from_bytes(&data).ok()?;
    value
        .as_dictionary()?
        .get("CFBundleIdentifier")?
        .as_string()
        .map(str::to_string)
}

fn sha256_hex(data: &[u8]) -> String {
    use sha2::{Digest, Sha256};
    let mut hasher = Sha256::new();
    hasher.update(data);
    hasher.finalize().iter().map(|b| format!("{b:02x}")).collect()
}
