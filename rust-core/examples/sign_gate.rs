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

/// The DER inside a PEM file, or the bytes as they are.
///
/// The key the app signs with is stored in a PKCS#12, and openssl writes it out
/// as PEM; `RustCryptoCmsSigner::from_der` wants the DER body.
fn read_der_or_pem(path: &str) -> Vec<u8> {
    let raw = fs::read(path).unwrap_or_else(|e| panic!("{path}: {e}"));
    let text = String::from_utf8_lossy(&raw);
    if !text.contains("-----BEGIN") {
        return raw;
    }
    let body: String = text
        .lines()
        .filter(|line| !line.starts_with("-----"))
        .collect();
    let compact: String = body.chars().filter(|c| !c.is_whitespace()).collect();
    base64_decode(&compact).unwrap_or_else(|| panic!("{path}: not base64"))
}

fn base64_decode(text: &str) -> Option<Vec<u8>> {
    const TABLE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = Vec::with_capacity(text.len() * 3 / 4);
    let mut acc: u32 = 0;
    let mut bits = 0;
    for ch in text.bytes() {
        if ch == b'=' {
            break;
        }
        let value = TABLE.iter().position(|&c| c == ch)? as u32;
        acc = (acc << 6) | value;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((acc >> bits) as u8);
        }
    }
    Some(out)
}

fn run() -> Result<(), String> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.len() < 3 {
        return Err("usage: sign_gate <app.app> <key.der> <cert.der> <chain.der|-> <main.mobileprovision> [<bundle-id>=<profile> ...]".into());
    }
    let app = PathBuf::from(&args[0]);
    let key = read_der_or_pem(&args[1]);
    let cert = read_der_or_pem(&args[2]);
    let chain = if args[3] == "-" { Vec::new() } else { read_der_or_pem(&args[3]) };
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
    // The app itself, then everything nested: the script compares each
    // bundle's embedded profile with the one issued for its identifier.
    describe(&app, &app, &mut out);
    walk(&app, &app, &mut out);
    print!("{out}");
    Ok(())
}

fn walk(root: &Path, dir: &Path, out: &mut String) {
    let Ok(entries) = fs::read_dir(dir) else { return };
    for entry in entries.flatten() {
        let path = entry.path();
        let name = entry.file_name().to_string_lossy().to_string();
        if path.is_dir() {
            if name.ends_with(".appex") || name.ends_with(".framework") {
                describe(root, &path, out);
            }
            walk(root, &path, out);
        }
    }
}

/// One bundle's identifier, whether it is sealed, and the profile it embeds.
fn describe(root: &Path, path: &Path, out: &mut String) {
    let key = rel(root, path);
    let has_sig = path.join("_CodeSignature").join("CodeResources").is_file();
    let id = plist_bundle_id(path).unwrap_or_default();
    out.push_str(&format!("bundle[{key}]={id}\n"));
    out.push_str(&format!("codesigned[{key}]={has_sig}\n"));
    match fs::read(path.join("embedded.mobileprovision")).ok() {
        Some(der) => out.push_str(&format!("embedded_sha256[{key}]={}\n", sha256_hex(&der))),
        None => out.push_str(&format!("embedded_sha256[{key}]=none\n")),
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
