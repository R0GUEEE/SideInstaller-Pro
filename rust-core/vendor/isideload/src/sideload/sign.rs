use apple_codesign_quick::{
    BundleSigningSettings, ProvisioningProfile, RustCryptoCmsSigner, sign_bundle,
};
use plist::Dictionary;
use rootcause::prelude::*;
use std::collections::{BTreeMap, BTreeSet};
use tracing::{info, warn};

use crate::{
    dev::{app_ids::Profile, teams::DeveloperTeam},
    sideload::{
        application::{Application, SpecialApp},
        cert_identity::CertificateIdentity,
    },
};

/// How long before its expiry a profile is refused. A free (personal team)
/// profile lives 7 days; signing one that is already inside this margin hands
/// the user an app that dies on first launch instead of an error they can act
/// on.
const EXPIRY_MARGIN_SECS: i64 = 60 * 60;

/// Signs the app and every bundle in it with apple-codesign-quick, which
/// hashes and signs nested bundles in parallel (upstream cc9fa9c, iLoader
/// 2.3.0), and embeds the provisioning profile while doing so.
///
/// Each extension receives the profile and entitlements issued for its own
/// bundle identifier. Frameworks and dylibs receive neither.
///
/// Before anything is removed or written, the bundle is checked against the
/// profiles it is about to be signed with: a missing, expired or mismatched
/// profile is an error here, not a signature that installs and then fails.
pub fn sign(
    app: &mut Application,
    cert_identity: &CertificateIdentity,
    provisioning_profile: &Profile,
    profiles: &std::collections::HashMap<String, Profile>,
    special: &Option<SpecialApp>,
    team: &DeveloperTeam,
) -> Result<(), Report> {
    let profile_der: &[u8] = provisioning_profile.encoded_profile.as_ref();
    let profile =
        ProvisioningProfile::parse(profile_der).context("Failed to parse provisioning profile")?;
    check_expiry(&profile, &provisioning_profile.name)?;
    let certificate_chain = cert_identity
        .profile_to_certificate_chain(&profile)
        .context("Failed to build the signing certificate chain")?;
    let signer = RustCryptoCmsSigner::new(
        cert_identity.private_key.clone(),
        cert_identity.certificate.clone(),
        certificate_chain,
    );

    let entitlements = entitlements(&profile, special, team);
    check_identity(&profile, &entitlements, app.main_bundle_id()?.as_str())?;

    clear_old_signatures(app)?;

    let mut settings = BundleSigningSettings::new(&team.team_id, entitlements.clone(), Some(&signer));
    settings.embedded_mobileprovision = Some(profile_der);
    let mut signed_bundle_ids = BTreeSet::new();
    signed_bundle_ids.insert(app.main_bundle_id()?);
    // One profile per identifier: apple-codesign-quick looks it up by the
    // bundle's `CFBundleIdentifier`, so a second bundle claiming an identifier
    // that is already spoken for would be handed the first one's profile — a
    // signature that claims another bundle's identity. Two extensions sharing
    // one is the usual way a sidestepped build gets there.
    let mut seen: BTreeMap<String, String> = BTreeMap::new();
    for bundle in app.bundle.collect_nested_bundles() {
        if bundle.bundle_dir.extension().and_then(|e| e.to_str()) != Some("appex") {
            continue;
        }
        let Some(bundle_id) = bundle.bundle_identifier() else {
            continue;
        };
        if let Some(first) = seen.get(bundle_id) {
            bail!(
                "{} and {} both carry the bundle identifier {bundle_id}; only one can be signed for it",
                first,
                bundle.bundle_dir.display()
            );
        }
        seen.insert(bundle_id.to_string(), bundle.bundle_dir.display().to_string());
        let extension_profile = profiles.get(bundle_id)
            .ok_or_else(|| report!("Missing provisioning profile for extension {bundle_id}"))?;
        let extension_der: &[u8] = extension_profile.encoded_profile.as_ref();
        let parsed = ProvisioningProfile::parse(extension_der)
            .context(format!("Failed to parse profile for extension {bundle_id}"))?;
        check_expiry(&parsed, &extension_profile.name)?;
        // The profile was requested for this identifier, but the check is what
        // catches a portal that answered with a wildcard or another app's.
        check_identity(&parsed, parsed.entitlements(), &bundle_id)?;
        signed_bundle_ids.insert(bundle_id.to_string());
        settings.embedded_mobileprovisions_by_bundle_id
            .insert(bundle_id.to_string(), extension_der);
        settings.entitlements_by_bundle_id
            .insert(bundle_id.to_string(), parsed.entitlements().clone());
    }

    // A `.appex` outside PlugIns (an SDK's helper inside `Frameworks/`) gets
    // the empty entitlement set and no profile, and nothing above notices: it
    // is not in `app_extensions`, so no profile was requested for it. It would
    // install and then never register with the extension host.
    let stray = stray_appexes(app);
    if let Some(path) = stray.first() {
        bail!(
            "{} is an app extension outside PlugIns ({} more), so it has no profile of its own; \
             remove it or move it out of Frameworks",
            path.display(),
            stray.len().saturating_sub(1)
        );
    }

    info!(
        "Signing {} and {} app extension(s)",
        app.bundle
            .bundle_dir
            .file_name()
            .unwrap_or(app.bundle.bundle_dir.as_os_str())
            .to_string_lossy(),
        settings.entitlements_by_bundle_id.len()
    );
    sign_bundle(&app.bundle.bundle_dir, &settings).context(format!(
        "Failed to sign bundle: {}",
        app.bundle.bundle_dir.display()
    ))?;

    Ok(())
}

/// Refuses a profile that has expired, or will within [`EXPIRY_MARGIN_SECS`].
///
/// `date_expire` is a UTC timestamp on the profile Apple issued; a device
/// clock ahead of Apple's or a profile cached from an earlier sign-in lands
/// here, where the install would otherwise succeed and the app fail at launch.
fn check_expiry(profile: &ProvisioningProfile, name: &str) -> Result<(), Report> {
    let Some(expiry) = profile.plist().get("ExpirationDate").and_then(|v| v.as_date()) else {
        // A profile without one is unsigned as far as expiry goes; Apple's all
        // carry it, and refusing here would block profiles that don't.
        return Ok(());
    };
    let left = std::time::SystemTime::from(expiry.clone())
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    let remaining = left - now;
    if remaining <= 0 {
        bail!("The provisioning profile \"{name}\" expired; sign in again to get a new one");
    }
    if remaining < EXPIRY_MARGIN_SECS {
        bail!(
            "The provisioning profile \"{name}\" expires in under a minute; sign in again to get a new one"
        );
    }
    Ok(())
}

/// The `application-identifier` a profile grants, and the team it names.
fn application_identifier(profile: &ProvisioningProfile, entitlements: &Dictionary) -> Option<String> {
    entitlements
        .get("application-identifier")
        .and_then(|v| v.as_string())
        .map(str::to_string)
        .or_else(|| {
            profile
                .plist()
                .get("Entitlements")
                .and_then(|v| v.as_dictionary())
                .and_then(|d| d.get("application-identifier"))
                .and_then(|v| v.as_string())
                .map(str::to_string)
        })
}

/// True when `identifier` is `app_id`, or one of its children (`app_id.…`).
fn covers(app_id: &str, identifier: &str) -> bool {
    if app_id == "*" {
        return true;
    }
    if let Some(rest) = app_id.strip_suffix(".*") {
        return identifier == rest || identifier.starts_with(&format!("{rest}."));
    }
    identifier == app_id || identifier.starts_with(&format!("{app_id}."))
}

/// The profile must grant the identifier it is being used for.
///
/// A wildcard profile (`TEAM.*`) covers every App ID on the team at once; an
/// explicit one is only valid for its own identifier (and, by Apple's rules,
/// the extensions beneath it). Getting this wrong produces a signature that
/// installs and then crashes in `amfid`.
fn check_identity(
    profile: &ProvisioningProfile,
    entitlements: &Dictionary,
    bundle_id: &str,
) -> Result<(), Report> {
    let Some(application_identifier) = application_identifier(profile, entitlements) else {
        return Ok(());
    };
    let Some((team, app_id)) = application_identifier.split_once('.') else {
        return Ok(());
    };
    if team.is_empty() || app_id.is_empty() {
        return Ok(());
    }
    if !covers(app_id, bundle_id) {
        bail!(
            "The provisioning profile grants {application_identifier}, which does not cover {bundle_id}"
        );
    }
    let profile_team = profile.team_id();
    if !profile_team.is_empty() && profile_team != team {
        warn!("Profile {application_identifier} names team {team}, signed with {profile_team}");
    }
    Ok(())
}

/// Every `.appex` that signs a nested bundle's lookup would miss: outside any
/// `PlugIns` folder, so it has no profile of its own.
///
/// `collect_nested_bundles` only descends `PlugIns` and `Frameworks`, and
/// `sign::sign` only hands profiles to `PlugIns`. An `.appex` under
/// `Frameworks/`, or inside a framework that has none, was signed with the
/// empty entitlement set before this check existed.
fn stray_appexes(app: &Application) -> Vec<std::path::PathBuf> {
    use std::path::Path;
    fn walk(dir: &Path, out: &mut Vec<std::path::PathBuf>, depth: usize) {
        if depth > 6 {
            return;
        }
        let Ok(entries) = std::fs::read_dir(dir) else {
            return;
        };
        for entry in entries.flatten() {
            let Ok(kind) = entry.file_type() else { continue };
            if !kind.is_dir() {
                continue;
            }
            let path = entry.path();
            if path.extension().and_then(|e| e.to_str()) == Some("appex") {
                out.push(path.clone());
                continue;
            }
            // A bundle's own `PlugIns` is where the signer does look; anything
            // under a `.framework` is not.
            if path.extension().and_then(|e| e.to_str()) == Some("framework")
                || path.file_name().and_then(|n| n.to_str()) == Some("Frameworks")
            {
                walk(&path, out, depth + 1);
            }
        }
    }
    let mut out = Vec::new();
    walk(&app.bundle.bundle_dir.join("Frameworks"), &mut out, 0);
    out
}

/// Deletes each bundle's `_CodeSignature` folder before it is signed again.
///
/// apple-codesign-quick replaces `CodeResources` but seals anything else it
/// finds in there, such as the `ResourceRules` some re-signed IPAs carry.
/// Nothing in `_CodeSignature` is ever a sealed resource, so verification then
/// fails with "a sealed resource is missing or invalid". The old signer
/// skipped the folder.
fn clear_old_signatures(app: &Application) -> Result<(), Report> {
    let nested = app.bundle.collect_nested_bundles();
    let bundle_dirs = std::iter::once(&app.bundle.bundle_dir).chain(nested.iter().map(|b| &b.bundle_dir));
    for bundle_dir in bundle_dirs {
        let signature_dir = bundle_dir.join("_CodeSignature");
        if signature_dir.is_dir() {
            std::fs::remove_dir_all(&signature_dir).context(format!(
                "Failed to remove the old signature in {}",
                bundle_dir.display()
            ))?;
        }
    }
    Ok(())
}

/// The profile's entitlements, plus the keychain groups LiveContainer needs.
///
/// The keychain groups are only added when the profile already has a
/// `keychain-access-groups` entry: an entitlement the profile does not carry
/// is one the signature must not either, or `amfid` rejects the launch.
fn entitlements(
    profile: &ProvisioningProfile,
    special: &Option<SpecialApp>,
    team: &DeveloperTeam,
) -> Dictionary {
    let mut entitlements = profile.entitlements().clone();

    if matches!(
        special,
        Some(SpecialApp::SideStoreLc) | Some(SpecialApp::LiveContainer)
    ) {
        let mut keychain_access = entitlements
            .get("keychain-access-groups")
            .and_then(|v| v.as_array())
            .cloned()
            .unwrap_or_default();
        if keychain_access.is_empty() {
            keychain_access.push(plist::Value::String(format!(
                "{}.com.kdt.livecontainer.shared",
                team.team_id
            )));
        }

        for number in 1..128 {
            keychain_access.push(plist::Value::String(format!(
                "{}.com.kdt.livecontainer.shared.{}",
                team.team_id, number
            )));
        }

        entitlements.insert(
            "keychain-access-groups".to_string(),
            plist::Value::Array(keychain_access),
        );
    }

    entitlements
}

#[cfg(test)]
mod tests {
    use super::*;

    fn dict(pairs: &[(&str, plist::Value)]) -> Dictionary {
        pairs
            .iter()
            .map(|(k, v)| (k.to_string(), v.clone()))
            .collect()
    }


    #[test]
    fn explicit_profiles_cover_their_own_identifier_and_children() {
        assert!(covers("com.example.app", "com.example.app"));
        assert!(covers("com.example.app", "com.example.app.widget"));
        assert!(!covers("com.example.app", "com.example.application"));
        assert!(!covers("com.example.app", "com.example.app2"));
    }

    #[test]
    fn wildcards_cover_every_identifier_under_their_prefix() {
        assert!(covers("TEAM.*", "anything.at.all"));
        assert!(covers("com.example.*", "com.example.app"));
        assert!(covers("com.example.*", "com.example"));
        assert!(!covers("com.example.*", "com.examples.app"));
    }

    #[test]
    fn team_prefix_and_identifier_are_split_on_the_first_dot() {
        // Apple writes `TEAMID.com.example.app`; the App ID is everything after
        // the first component.
        let (team, app_id) = "ABCDE12345.com.example.app"
            .split_once('.')
            .unwrap();
        assert_eq!(team, "ABCDE12345");
        assert!(covers(app_id, "ABCDE12345.com.example.app".split_once('.').unwrap().1));
    }
}
