//! Desktop system proxy control.
//! Full implementation is Windows-only; other hosts get a clear stub for CI/dev.

use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ProxyEndpoint {
    pub host: String,
    pub port: u16,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct SystemProxyStatus {
    pub enabled: bool,
    pub managed_by_viasix: bool,
    pub endpoint: Option<ProxyEndpoint>,
    pub message: String,
}

#[cfg(windows)]
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Snapshot {
    previous_enable: u32,
    previous_server: String,
    previous_override: String,
    applied_server: String,
}

pub struct SystemProxyManager {
    snapshot_path: PathBuf,
}

/// Pure decision for `disable`: what to do with the registry and the snapshot.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[cfg_attr(not(windows), allow(dead_code))]
pub(crate) enum DisableAction {
    /// No ViaSix snapshot — ViaSix never enabled the proxy; leave the user's settings alone.
    LeaveUntouched,
    /// Registry still holds our applied server — restore the snapshot, then delete it.
    RestoreAndDelete,
    /// User changed the proxy after ViaSix enabled it — keep theirs, drop the stale snapshot.
    DeleteSnapshotOnly,
}

#[cfg_attr(not(windows), allow(dead_code))]
pub(crate) fn disable_action(
    has_snapshot: bool,
    cur_enabled: bool,
    cur_server: &str,
    applied_server: &str,
) -> DisableAction {
    if !has_snapshot {
        return DisableAction::LeaveUntouched;
    }
    if cur_enabled && cur_server == applied_server {
        DisableAction::RestoreAndDelete
    } else {
        DisableAction::DeleteSnapshotOnly
    }
}

impl SystemProxyManager {
    pub fn new(data_dir: PathBuf) -> Self {
        Self {
            snapshot_path: data_dir.join("system-proxy-snapshot.json"),
        }
    }

    pub fn status(&self) -> SystemProxyStatus {
        platform::status(&self.snapshot_path)
    }

    pub fn enable(&self, endpoint: &ProxyEndpoint) -> Result<SystemProxyStatus, String> {
        if endpoint.host.trim().is_empty() {
            return Err("proxy host is empty".into());
        }
        if endpoint.port == 0 {
            return Err("proxy port is invalid".into());
        }
        platform::enable(endpoint, &self.snapshot_path)?;
        Ok(self.status())
    }

    pub fn disable(&self) -> Result<SystemProxyStatus, String> {
        platform::disable(&self.snapshot_path)?;
        Ok(self.status())
    }
}

#[cfg(windows)]
mod platform {
    use super::{ProxyEndpoint, Snapshot, SystemProxyStatus};
    use std::fs;
    use std::path::Path;
    use winreg::enums::{HKEY_CURRENT_USER, KEY_READ};
    use winreg::RegKey;
    use windows_sys::Win32::Networking::WinInet::{
        InternetSetOptionW, INTERNET_OPTION_REFRESH, INTERNET_OPTION_SETTINGS_CHANGED,
    };

    const KEY_PATH: &str = r"Software\Microsoft\Windows\CurrentVersion\Internet Settings";

    pub fn status(snapshot_path: &Path) -> SystemProxyStatus {
        match read_settings() {
            Ok((enable, server, _)) => {
                let managed = snapshot_path.is_file();
                let endpoint = parse_server(&server);
                SystemProxyStatus {
                    enabled: enable != 0,
                    managed_by_viasix: managed,
                    endpoint,
                    message: if enable != 0 {
                        format!("System proxy on ({server})")
                    } else {
                        "System proxy off".into()
                    },
                }
            }
            Err(err) => SystemProxyStatus {
                enabled: false,
                managed_by_viasix: false,
                endpoint: None,
                message: format!("Unable to read system proxy: {err}"),
            },
        }
    }

    pub fn enable(endpoint: &ProxyEndpoint, snapshot_path: &Path) -> Result<(), String> {
        let (prev_enable, prev_server, prev_override) = read_settings()?;
        let applied = format!("{}:{}", endpoint.host.trim(), endpoint.port);

        // Only snapshot the first enable in a managed session.
        if !snapshot_path.is_file() {
            let snapshot = Snapshot {
                previous_enable: prev_enable,
                previous_server: prev_server,
                previous_override: prev_override.clone(),
                applied_server: applied.clone(),
            };
            if let Some(parent) = snapshot_path.parent() {
                fs::create_dir_all(parent).map_err(|e| e.to_string())?;
            }
            let data = serde_json::to_vec_pretty(&snapshot).map_err(|e| e.to_string())?;
            fs::write(snapshot_path, data).map_err(|e| e.to_string())?;
        }

        let override_list = merge_bypass(&prev_override);
        write_settings(1, &applied, &override_list)?;
        notify_system()?;
        Ok(())
    }

    pub fn disable(snapshot_path: &Path) -> Result<(), String> {
        // No snapshot means ViaSix never enabled the proxy — never touch the
        // user's own settings (launch recovery / tray quit call this blindly).
        if !snapshot_path.is_file() {
            return Ok(());
        }
        let raw = fs::read_to_string(snapshot_path).map_err(|e| e.to_string())?;
        let snapshot: Snapshot = serde_json::from_str(&raw).map_err(|e| e.to_string())?;
        let (cur_enable, cur_server, _) = read_settings()?;
        let action = super::disable_action(
            true,
            cur_enable != 0,
            &cur_server,
            &snapshot.applied_server,
        );
        if action == super::DisableAction::RestoreAndDelete {
            write_settings(
                snapshot.previous_enable,
                &snapshot.previous_server,
                &snapshot.previous_override,
            )?;
            notify_system()?;
        }
        let _ = fs::remove_file(snapshot_path);
        Ok(())
    }

    fn read_settings() -> Result<(u32, String, String), String> {
        let hkcu = RegKey::predef(HKEY_CURRENT_USER);
        let key = hkcu
            .open_subkey_with_flags(KEY_PATH, KEY_READ)
            .map_err(|e| format!("open Internet Settings: {e}"))?;
        let enable: u32 = key.get_value("ProxyEnable").unwrap_or(0);
        let server: String = key.get_value("ProxyServer").unwrap_or_default();
        let bypass: String = key.get_value("ProxyOverride").unwrap_or_default();
        Ok((enable, server, bypass))
    }

    fn write_settings(enable: u32, server: &str, bypass: &str) -> Result<(), String> {
        let hkcu = RegKey::predef(HKEY_CURRENT_USER);
        let (key, _) = hkcu
            .create_subkey(KEY_PATH)
            .map_err(|e| format!("open Internet Settings for write: {e}"))?;
        key.set_value("ProxyEnable", &enable)
            .map_err(|e| format!("set ProxyEnable: {e}"))?;
        key.set_value("ProxyServer", &server)
            .map_err(|e| format!("set ProxyServer: {e}"))?;
        key.set_value("ProxyOverride", &bypass)
            .map_err(|e| format!("set ProxyOverride: {e}"))?;
        Ok(())
    }

    fn notify_system() -> Result<(), String> {
        unsafe {
            // NULL handle + SETTINGS_CHANGED / REFRESH notifies WinINet consumers.
            if InternetSetOptionW(std::ptr::null_mut(), INTERNET_OPTION_SETTINGS_CHANGED, std::ptr::null_mut(), 0)
                == 0
            {
                return Err("InternetSetOption SETTINGS_CHANGED failed".into());
            }
            if InternetSetOptionW(std::ptr::null_mut(), INTERNET_OPTION_REFRESH, std::ptr::null_mut(), 0) == 0 {
                return Err("InternetSetOption REFRESH failed".into());
            }
        }
        Ok(())
    }

    fn parse_server(server: &str) -> Option<ProxyEndpoint> {
        let server = server.trim();
        if server.is_empty() {
            return None;
        }
        // Accept host:port or scheme=host:port lists; take first http-ish token.
        let token = server
            .split(';')
            .next()
            .unwrap_or(server)
            .split('=')
            .next_back()
            .unwrap_or(server)
            .trim();
        let (host, port_str) = token.rsplit_once(':')?;
        let port: u16 = port_str.parse().ok()?;
        Some(ProxyEndpoint {
            host: host.to_string(),
            port,
        })
    }

    fn merge_bypass(existing: &str) -> String {
        let mut parts: Vec<String> = existing
            .split(';')
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(str::to_string)
            .collect();
        for required in ["<local>", "localhost", "127.*", "127.0.0.1"] {
            if !parts.iter().any(|p| p.eq_ignore_ascii_case(required)) {
                parts.push(required.to_string());
            }
        }
        parts.join(";")
    }
}

#[cfg(not(windows))]
mod platform {
    use super::{ProxyEndpoint, SystemProxyStatus};
    use std::path::Path;

    pub fn status(_snapshot_path: &Path) -> SystemProxyStatus {
        SystemProxyStatus {
            enabled: false,
            managed_by_viasix: false,
            endpoint: None,
            message: "System proxy is only available on Windows builds".into(),
        }
    }

    pub fn enable(_endpoint: &ProxyEndpoint, _snapshot_path: &Path) -> Result<(), String> {
        Err("System proxy is only available on Windows builds".into())
    }

    pub fn disable(_snapshot_path: &Path) -> Result<(), String> {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn manager_status_is_safe_on_this_host() {
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let dir = std::env::temp_dir().join(format!("viasix-proxy-test-{stamp}"));
        let _ = fs::create_dir_all(&dir);
        let manager = SystemProxyManager::new(dir.clone());
        let status = manager.status();
        assert!(!status.message.is_empty());
        let _ = fs::remove_dir_all(dir);
    }

    #[test]
    fn disable_without_snapshot_leaves_user_proxy_untouched() {
        // Crash-recovery / tray-quit call disable blindly; a user-enabled proxy
        // must survive when ViaSix never took a snapshot.
        let action = disable_action(false, true, "corp-proxy:8080", "");
        assert_eq!(action, DisableAction::LeaveUntouched);
    }

    #[test]
    fn disable_restores_only_when_our_server_is_still_applied() {
        let action = disable_action(true, true, "127.0.0.1:11451", "127.0.0.1:11451");
        assert_eq!(action, DisableAction::RestoreAndDelete);
    }

    #[test]
    fn disable_keeps_user_chosen_proxy_after_switch() {
        // User switched to another proxy after ViaSix enabled ours — keep theirs.
        let action = disable_action(true, true, "corp-proxy:8080", "127.0.0.1:11451");
        assert_eq!(action, DisableAction::DeleteSnapshotOnly);
    }

    #[test]
    fn disable_drops_stale_snapshot_when_proxy_already_off() {
        let action = disable_action(true, false, "127.0.0.1:11451", "127.0.0.1:11451");
        assert_eq!(action, DisableAction::DeleteSnapshotOnly);
    }
}
