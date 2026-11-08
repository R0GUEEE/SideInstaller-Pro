use crate::{
    dev::{
        app_groups::AppGroupsApi,
        app_ids::AppIdsApi,
        developer_session::DeveloperSession,
        devices::DevicesApi,
        teams::{DeveloperTeam, TeamsApi},
    },
    sideload::{
        TeamSelection,
        application::{Application, SpecialApp},
        builder::MaxCertsBehavior,
        cert_identity::CertificateIdentity,
        sign,
    },
    util::{device::IdeviceInfo, storage::SideloadingStorage},
};

use std::path::PathBuf;

use futures_util::future::{try_join, try_join3, try_join_all};
use idevice::provider::IdeviceProvider;
use rootcause::{option_ext::OptionExt, prelude::*};
use tracing::{info, warn};

pub struct Sideloader {
    team_selection: TeamSelection,
    storage: Box<dyn SideloadingStorage>,
    dev_session: DeveloperSession,
    machine_name: String,
    apple_email: String,
    max_certs_behavior: MaxCertsBehavior,
    //extensions_behavior: ExtensionsBehavior,
    delete_app_after_install: bool,
    team: Option<DeveloperTeam>,
}

impl Sideloader {
    /// Construct a new `Sideloader` instance with the provided configuration
    ///
    /// See [`crate::sideload::SideloaderBuilder`] for more details and a more convenient way to construct a `Sideloader`.
    pub fn new(
        dev_session: DeveloperSession,
        apple_email: String,
        team_selection: TeamSelection,
        max_certs_behavior: MaxCertsBehavior,
        machine_name: String,
        storage: Box<dyn SideloadingStorage>,
        //extensions_behavior: ExtensionsBehavior,
        delete_app_after_install: bool,
    ) -> Self {
        Sideloader {
            team_selection,
            storage,
            dev_session,
            machine_name,
            apple_email,
            max_certs_behavior,
            //extensions_behavior,
            delete_app_after_install,
            team: None,
        }
    }

    /// Sign the app at the provided path and return the path to the signed app bundle (in a temp dir). To sign and install, see [`Self::install_app`].
    ///
    /// `register_device` is a device's (name, UDID) to register with the team
    /// first, since the provisioning profile only covers registered devices.
    /// `pairing_file` is that device's RPPairing record, which goes encrypted
    /// into AltStore's bundle and is ignored for every other app.
    /// `app_group` is false for an app that renews its own profile (Madeira):
    /// its App IDs then get no app group, so that a new App ID it registers
    /// later, which comes with none, yields a profile that still covers it.
    #[allow(clippy::too_many_arguments)]
    pub async fn sign_app(
        &mut self,
        app_path: PathBuf,
        team: Option<DeveloperTeam>,
        // this will be replaced with proper entitlement handling later
        increased_memory_limit: bool,
        app_group: bool,
        register_device: Option<(&str, &str)>,
        pairing_file: Option<&[u8]>,
    ) -> Result<(PathBuf, Option<SpecialApp>), Report> {
        let team = match team {
            Some(t) => t,
            None => self.get_team().await?,
        };

        // Requests that don't depend on each other go out together, each on its
        // own copy of the developer session. Anisette headers are fetched once
        // first, so every copy reuses them instead of asking the server again.
        self.dev_session
            .get_headers()
            .await
            .context("Failed to get anisette headers")?;
        let mut device_session = self.dev_session.clone();
        let mut cert_session = self.dev_session.clone();
        let mut app_id_session = self.dev_session.clone();
        let mut group_session = self.dev_session.clone();

        let registration = async {
            if let Some((name, udid)) = register_device
                && let Err(e) = device_session
                    .ensure_device_registered(&team, name, udid, None)
                    .await
            {
                bail!("device registration failed for UDID {udid}: {e}");
            }
            Ok::<(), Report>(())
        };

        let certificate = async {
            Ok::<_, Report>(
                CertificateIdentity::retrieve(
                    &self.machine_name,
                    &self.apple_email,
                    &mut cert_session,
                    &team,
                    self.storage.as_ref(),
                    &self.max_certs_behavior,
                )
                .await
                .context("Failed to retrieve certificate identity")?,
            )
        };

        // Extracting the archive is blocking work, so it runs off this task and
        // the requests above keep moving meanwhile.
        let bundle = async {
            let mut app = tokio::task::spawn_blocking(move || Application::new(app_path))
                .await
                .map_err(|e| report!("Failed to open application archive: {e}"))??;
            let special = app.get_special_app();

            let main_bundle_id = app.main_bundle_id()?;
            let main_app_name = app.main_app_name()?;
            let main_app_id_str = format!("{}.{}", main_bundle_id, team.team_id);
            app.update_bundle_id(&main_bundle_id, &main_app_id_str)?;

            let group_identifier = format!(
                "group.{}",
                if Some(SpecialApp::SideStoreLc) == special {
                    format!("com.SideStore.SideStore.{}", team.team_id)
                } else {
                    main_app_id_str.clone()
                }
            );

            // A wildcard profile (`TEAM.*`) already covers any identifier on
            // the team, so a team made of them needs no App ID per extension.
            let wildcard_covers_all = team_uses_wildcard_profiles(&mut app_id_session, &team).await;
            if wildcard_covers_all && app_group {
                warn!(
                    "This team's profiles are wildcard ones, so an app group is not granted and \
                     the app is signed without one"
                );
            }

            let (mut app_ids, app_group) = try_join(
                app.register_app_ids(&mut app_id_session, &team, wildcard_covers_all),
                async {
                    if !app_group || wildcard_covers_all {
                        return Ok(None);
                    }
                    group_session
                        .ensure_app_group(&team, &main_app_name, &group_identifier, None)
                        .await
                        .map(Some)
                },
            )
            .await?;

            let main_app_id = app_ids
                .iter()
                .find(|app_id| app_id.identifier == main_app_id_str)
            .cloned()
            .ok_or_else(|| {
                report!(
                    "Main app ID {} not found in registered app IDs",
                    main_app_id_str
                )
            })?;
            // A wildcard team's main App ID is not among the team's App IDs (it
            // may not exist at all); the profile lookup below only needs an
            // identifier, and the profile will be the wildcard one.

            // Each App ID is configured on its own session, all at once.
            try_join_all(app_ids.iter_mut().map(|app_id| {
                let mut session = app_id_session.clone();
                let (team, app_group) = (&team, &app_group);
                async move {
                    if let Some(app_group) = app_group {
                        app_id.ensure_group_feature(&mut session, team).await?;
                        session
                            .assign_app_group(team, app_group, app_id, None)
                            .await?;
                        // The profile is built from the App ID as Apple now
                        // holds it. Reading it back is what catches a PATCH
                        // Apple accepted without applying: the profile would
                        // then lack `application-groups` while the signature
                        // followed the profile, and the app would be installed
                        // with a shared container it cannot open.
                        session
                            .require_app_group_feature(team, app_id, app_group.identifier.as_str())
                            .await?;
                    }
                    if increased_memory_limit {
                        session.add_increased_memory_limit(team, app_id).await?;
                        session
                            .require_capability(team, app_id, "increasedMemoryLimit")
                            .await?;
                    }
                    Ok::<(), Report>(())
                }
            }))
            .await?;

            info!("App IDs configured");
            Ok::<_, Report>((app, special, group_identifier, main_app_id, app_ids))
        };

        let ((), cert_identity, (mut app, special, group_identifier, main_app_id, app_ids)) =
            try_join3(registration, certificate, bundle).await?;


        // The profile has to come after the device and App IDs are set up; the
        // certificate goes into the bundle meanwhile.
        let dev_session = &mut self.dev_session;
        let ((), profiles) = try_join(
            async {
                app.apply_special_app_behavior(
                    &special,
                    &group_identifier,
                    &cert_identity,
                    register_device.map(|(_, udid)| udid),
                    pairing_file,
                )
                .await
                .context("Failed to modify app bundle")?;
                Ok::<(), Report>(())
            },
            async {
                let mut profiles = std::collections::HashMap::new();
                let mut unsigned: Vec<String> = Vec::new();
                for app_id in &app_ids {
                    let profile = dev_session
                        .download_team_provisioning_profile(&team, app_id, None)
                        .await?;
                    profiles.insert(app_id.identifier.clone(), profile);
                }
                // Every App ID is kept on the team, signed or not, so the list
                // of profiles and the list of App IDs stay in step. A wildcard
                // team lists App IDs created by other installs; those get no
                // request, and no extension will be looking one up.
                let wanted: std::collections::HashSet<&str> = app_ids
                    .iter()
                    .map(|app_id| app_id.identifier.as_str())
                    .collect();
                for id in app.bundle.collect_nested_bundles().iter().filter_map(|b| {
                    (b.bundle_dir.extension().and_then(|e| e.to_str()) == Some("appex"))
                        .then(|| b.bundle_identifier().map(str::to_string))
                        .flatten()
                }) {
                    if !wanted.contains(id.as_str()) && !unsigned.contains(&id) {
                        unsigned.push(id);
                    }
                }
                if !unsigned.is_empty() {
                    warn!(
                        "{} app extension(s) have no App ID of their own and are signed with the \
                         empty entitlement set: {}",
                        unsigned.len(),
                        unsigned.join(", ")
                    );
                }
                info!("Acquired {} provisioning profiles", profiles.len());
                Ok::<_, Report>(profiles)
            },
        )
        .await?;

        app.bundle.write_info()?;
        for ext in app.bundle.app_extensions_mut() {
            ext.write_info()?;
        }
        for ext in app.bundle.frameworks_mut() {
            ext.write_info()?;
        }

        // `sign` writes embedded.mobileprovision into the app and each .appex
        // as it signs them, since the profile is sealed into CodeResources.
        // Hosts read an extension's copy back: AltStore-family apps reject an
        // extension without one.
        let provisioning_profile = profiles.get(&main_app_id.identifier)
            .ok_or_else(|| report!("Missing main app provisioning profile"))?;
        sign::sign(
            &mut app,
            &cert_identity,
            provisioning_profile,
            &profiles,
            &special,
            &team,
        )
        .context("Failed to sign app")?;

        info!("App signed!");

        Ok((app.bundle.bundle_dir.clone(), special))
    }

    #[cfg(feature = "install")]
    /// Sign and install an app to a device. `pairing_file` is as for
    /// [`Self::sign_app`].
    pub async fn install_app(
        &mut self,
        device_provider: &impl IdeviceProvider,
        app_path: PathBuf,
        // this is gross but will be replaced with proper entitlement handling later
        increased_memory_limit: bool,
        pairing_file: Option<&[u8]>,
    ) -> Result<Option<SpecialApp>, Report> {
        let device_info = IdeviceInfo::from_device(device_provider).await?;

        let team = self.get_team().await?;
        let (signed_app_path, special_app) = self
            .sign_app(
                app_path,
                Some(team),
                increased_memory_limit,
                true,
                Some((&device_info.name, &device_info.udid)),
                pairing_file,
            )
            .await?;

        info!("Transferring App...");

        crate::sideload::install::install_app(device_provider, &signed_app_path, |progress| {
            info!("Installing: {}%", progress);
        })
        .await
        .context("Failed to install app on device")?;

        if self.delete_app_after_install
            && let Err(e) = tokio::fs::remove_dir_all(signed_app_path).await
        {
            tracing::warn!("Failed to remove temporary signed app file: {}", e);
        }

        Ok(special_app)
    }

    /// Get the developer team according to the configured team selection behavior
    pub async fn get_team(&mut self) -> Result<DeveloperTeam, Report> {
        if let Some(team) = &self.team {
            return Ok(team.clone());
        }
        let teams = self.dev_session.list_teams().await?;
        let team = match teams.len() {
            0 => {
                bail!("No developer teams available")
            }
            1 => teams.into_iter().next().ok_or_report()?,
            _ => {
                info!(
                    "Multiple developer teams found, {} as per configuration",
                    self.team_selection
                );
                match &self.team_selection {
                    TeamSelection::First => teams.into_iter().next().ok_or_report()?,
                    TeamSelection::PromptOnce(prompt_fn)
                    | TeamSelection::PromptAlways(prompt_fn) => {
                        let selection =
                            prompt_fn(&teams).ok_or_else(|| report!("No team selected"))?;
                        teams
                            .into_iter()
                            .find(|t| t.team_id == selection)
                            .ok_or_else(|| report!("No team found with ID {}", selection))?
                    }
                }
            }
        };
        if !matches!(&self.team_selection, TeamSelection::PromptAlways(_)) {
            self.team = Some(team.clone());
        }
        Ok(team)
    }

    /// Use `team` without asking Apple, for a caller that has already listed the
    /// teams and picked one as the team selection would.
    pub fn set_team(&mut self, team: DeveloperTeam) {
        self.team = Some(team);
    }

    pub fn get_dev_session(&mut self) -> &mut DeveloperSession {
        &mut self.dev_session
    }

    pub fn get_email(&self) -> &str {
        &self.apple_email
    }
}

/// Whether every provisioning profile the team currently holds is a wildcard
/// one (`TEAM.*`).
///
/// A wildcard profile covers every identifier on the team, so no App ID has to
/// be registered for an app or its extensions, and no capability can be granted
/// on an App ID. Asking for the team's profiles and reading what came back is
/// the only place the answer exists. An answer that can't be read counts as
/// "no": the App IDs are then registered the ordinary way, and the profiles
/// Apple issues are whatever they are.
async fn team_uses_wildcard_profiles(dev_session: &mut DeveloperSession, team: &DeveloperTeam) -> bool {
    #[derive(serde::Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct Entry {
        #[serde(default)]
        provisioning_profile_id: Option<String>,
        #[serde(default)]
        name: Option<String>,
        #[serde(default, rename = "type")]
        kind: Option<String>,
        #[serde(default)]
        app_id_id: Option<String>,
    }
    #[derive(serde::Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct Listing {
        #[serde(default)]
        provisioning_profiles: Vec<Entry>,
    }

    let body = plist_macro::plist!(dict { "teamId": &team.team_id });
    let url = crate::dev::device_type::dev_url("listProvisioningProfiles", None);
    let listed: Result<Listing, _> = dev_session
        .send_dev_request(&url, body, "provisioningProfileList")
        .await;
    let Ok(listing) = listed else {
        return false;
    };
    if listing.provisioning_profiles.is_empty() {
        return false;
    }
    listing
        .provisioning_profiles
        .iter()
        .all(|entry| is_wildcard_profile(entry.kind.as_deref(), entry.name.as_deref()))
}

fn is_wildcard_profile(kind: Option<&str>, name: Option<&str>) -> bool {
    if let Some(kind) = kind
        && kind.to_ascii_uppercase().contains("WILDCARD")
    {
        return true;
    }
    name.map(|name| name.contains(".*")).unwrap_or(false)
}

#[cfg(test)]
mod wildcard_tests {
    use super::is_wildcard_profile;

    #[test]
    fn a_dev_profile_named_for_the_team_is_a_wildcard() {
        assert!(is_wildcard_profile(Some("IOS_APP_DEVELOPMENT"), Some("iOS Team Provisioning Profile: *")));
        assert!(is_wildcard_profile(None, Some("QH65B2.*")));
    }

    #[test]
    fn an_app_specific_profile_is_not() {
        assert!(!is_wildcard_profile(
            Some("IOS_APP_DEVELOPMENT"),
            Some("iOS Team Provisioning Profile: com.example.app")
        ));
        assert!(!is_wildcard_profile(None, None));
    }
}
