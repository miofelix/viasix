//! User-space Mihomo process supervision (Windows MVP).

use crate::projection::{project_runtime_yaml, ProjectOptions};
use parking_lot::Mutex;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
// Path used by log banner helper
use std::process::{Child, Command, Stdio};
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CoreStatus {
    pub running: bool,
    pub pid: Option<u32>,
    pub message: String,
    pub controller_port: Option<u16>,
}

/// Outcome of a watcher poll for a specific start generation.
#[derive(Debug, PartialEq, Eq)]
pub enum WatchOutcome {
    StillRunning,
    /// Session was stopped or replaced — the watcher should end quietly.
    Detached,
    /// Child exited without a stop() call (crash, port conflict, kill).
    Exited(String),
}

pub struct CoreRuntime {
    inner: Mutex<Inner>,
}

struct Inner {
    child: Option<Child>,
    work_dir: PathBuf,
    controller_port: Option<u16>,
    controller_secret: Option<String>,
    log_path: PathBuf,
    /// Session id of the current run; bumped on start/stop/exit so stale watchers detach.
    generation: u64,
    /// Unexpected exit reaped by `status()` before the watcher saw it: (session id, reason).
    pending_exit: Option<(u64, String)>,
}

impl CoreRuntime {
    pub fn new(work_dir: PathBuf) -> Self {
        let log_path = work_dir.join("mihomo.log");
        Self {
            inner: Mutex::new(Inner {
                child: None,
                work_dir,
                controller_port: None,
                controller_secret: None,
                log_path,
                generation: 0,
                pending_exit: None,
            }),
        }
    }

    pub fn log_path(&self) -> PathBuf {
        self.inner.lock().log_path.clone()
    }

    /// Return the last `max_lines` of the mihomo process log (stdout/stderr).
    pub fn tail_log(&self, max_lines: usize) -> Result<String, String> {
        let path = self.log_path();
        if !path.is_file() {
            return Ok(String::new());
        }
        let raw = fs::read_to_string(&path).map_err(io_err)?;
        let lines: Vec<&str> = raw.lines().collect();
        let take = max_lines.max(1);
        let start = lines.len().saturating_sub(take);
        Ok(lines[start..].join("\n"))
    }

    pub fn status(&self) -> CoreStatus {
        let mut guard = self.inner.lock();
        self.reap_if_exited(&mut guard);
        match guard.child.as_ref() {
            Some(child) => CoreStatus {
                running: true,
                pid: Some(child.id()),
                message: format!("Mihomo running (pid {})", child.id()),
                controller_port: guard.controller_port,
            },
            None => CoreStatus {
                running: false,
                pid: None,
                message: "Mihomo stopped".into(),
                controller_port: None,
            },
        }
    }

    pub fn controller_credentials(&self) -> Option<(u16, String)> {
        let guard = self.inner.lock();
        match (&guard.controller_port, &guard.controller_secret) {
            (Some(port), Some(secret)) if guard.child.is_some() => Some((*port, secret.clone())),
            _ => None,
        }
    }

    pub fn start(
        &self,
        profile_yaml: Option<&str>,
        options: &ProjectOptions,
        mihomo_bin: &Path,
    ) -> Result<CoreStatus, String> {
        let mut guard = self.inner.lock();
        self.reap_if_exited(&mut guard);
        if guard.child.is_some() {
            return Err("Mihomo is already running".into());
        }

        if !mihomo_bin.is_file() {
            return Err(format!(
                "Mihomo binary not found at {}. Run `pnpm prebuild` first.",
                mihomo_bin.display()
            ));
        }

        let mut options = options.clone();
        if options.controller_secret.as_deref().unwrap_or("").is_empty() {
            let nanos = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map(|d| d.as_nanos())
                .unwrap_or(0);
            options.controller_secret = Some(format!("viasix{nanos:x}"));
        }

        let runtime_yaml = project_runtime_yaml(profile_yaml, &options)
            .map_err(|e| e.contract_code().to_string())?;

        fs::create_dir_all(&guard.work_dir).map_err(io_err)?;
        let config_path = guard.work_dir.join("runtime.yaml");
        fs::write(&config_path, runtime_yaml).map_err(io_err)?;

        // Capture kernel logs for diagnostics (macOS uses a unified log channel).
        let log_file = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&guard.log_path)
            .map_err(io_err)?;
        let log_err = log_file
            .try_clone()
            .map_err(io_err)?;
        let _ = writeln_banner(&guard.log_path);

        let mut command = Command::new(mihomo_bin);
        command
            .arg("-f")
            .arg(&config_path)
            .arg("-d")
            .arg(&guard.work_dir)
            .stdin(Stdio::null())
            .stdout(Stdio::from(log_file))
            .stderr(Stdio::from(log_err));

        let mut child = command.spawn().map_err(|e| {
            format!(
                "failed to spawn mihomo ({}): {e}",
                mihomo_bin.display()
            )
        })?;

        // A bad runtime.yaml or port conflict makes mihomo exit within
        // milliseconds — catch that here instead of reporting a dead "success".
        verify_spawn_liveness(&mut child)?;

        let pid = child.id();
        guard.child = Some(child);
        guard.controller_port = Some(options.controller_port);
        guard.controller_secret = options.controller_secret.clone();
        guard.generation += 1;
        Ok(CoreStatus {
            running: true,
            pid: Some(pid),
            message: format!(
                "Mihomo started (pid {pid}, controller 127.0.0.1:{})",
                options.controller_port
            ),
            controller_port: Some(options.controller_port),
        })
    }

    /// Generation of the current session; pass to `watch_poll` so a watcher
    /// spawned for one start never acts on a later session.
    pub fn generation(&self) -> u64 {
        self.inner.lock().generation
    }

    /// One watcher poll step for the session identified by `generation`.
    pub fn watch_poll(&self, generation: u64) -> WatchOutcome {
        let mut guard = self.inner.lock();
        // status()/reap may have observed the exit first; hand it to the watcher.
        if let Some((gen, reason)) = guard.pending_exit.take() {
            if gen == generation {
                return WatchOutcome::Exited(reason);
            }
            if gen > generation {
                // Belongs to a newer session; put it back for that watcher.
                guard.pending_exit = Some((gen, reason));
            }
        }
        if guard.generation != generation {
            return WatchOutcome::Detached;
        }
        let Some(child) = guard.child.as_mut() else {
            return WatchOutcome::Detached;
        };
        let exit = match child.try_wait() {
            Ok(None) => return WatchOutcome::StillRunning,
            Ok(Some(status)) => format!("Mihomo exited unexpectedly ({status})"),
            Err(err) => format!("Mihomo state check failed: {err}"),
        };
        guard.child = None;
        guard.controller_port = None;
        guard.controller_secret = None;
        guard.generation += 1;
        WatchOutcome::Exited(exit)
    }

    pub fn stop(&self) -> Result<CoreStatus, String> {
        let mut guard = self.inner.lock();
        self.reap_if_exited(&mut guard);
        if let Some(mut child) = guard.child.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
        guard.controller_port = None;
        guard.controller_secret = None;
        guard.generation += 1;
        // Deliberate stop supersedes any exit observed moments earlier.
        guard.pending_exit = None;
        Ok(CoreStatus {
            running: false,
            pid: None,
            message: "Mihomo stopped".into(),
            controller_port: None,
        })
    }

    fn reap_if_exited(&self, guard: &mut Inner) {
        if let Some(child) = guard.child.as_mut() {
            match child.try_wait() {
                Ok(None) => {}
                Ok(Some(status)) => {
                    let gen = guard.generation;
                    guard.pending_exit = Some((gen, format!("Mihomo exited unexpectedly ({status})")));
                    Self::clear_session(guard);
                }
                Err(err) => {
                    let gen = guard.generation;
                    guard.pending_exit = Some((gen, format!("Mihomo state check failed: {err}")));
                    Self::clear_session(guard);
                }
            }
        }
    }

    fn clear_session(guard: &mut Inner) {
        guard.child = None;
        guard.controller_port = None;
        guard.controller_secret = None;
        guard.generation += 1;
    }
}

/// Poll `try_wait` briefly after spawn; reject an instant exit as a start failure.
fn verify_spawn_liveness(child: &mut Child) -> Result<(), String> {
    const CHECKS: u32 = 8;
    const INTERVAL: Duration = Duration::from_millis(50);
    for _ in 0..CHECKS {
        match child.try_wait() {
            Ok(None) => std::thread::sleep(INTERVAL),
            Ok(Some(status)) => {
                return Err(format!(
                    "Mihomo exited immediately after start ({status}); check runtime.yaml and port usage in the kernel log"
                ));
            }
            Err(err) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(format!("Mihomo liveness check failed: {err}"));
            }
        }
    }
    Ok(())
}

fn io_err(err: io::Error) -> String {
    err.to_string()
}

fn writeln_banner(path: &Path) -> io::Result<()> {
    use std::io::Write;
    let mut file = fs::OpenOptions::new().create(true).append(true).open(path)?;
    writeln!(
        file,
        "\n----- viasix mihomo session {} -----",
        chrono_like_stamp()
    )?;
    Ok(())
}

fn chrono_like_stamp() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    format!("unix={secs}")
}

pub type SharedCore = Arc<CoreRuntime>;

#[cfg(test)]
mod tests {
    use super::*;
    use std::process::Command;

    #[cfg(unix)]
    #[test]
    fn liveness_rejects_instant_exit() {
        let mut child = Command::new("sh")
            .args(["-c", "exit 3"])
            .spawn()
            .expect("spawn sh");
        let err = verify_spawn_liveness(&mut child).expect_err("instant exit must fail");
        assert!(err.contains("exited immediately"), "{err}");
    }

    #[cfg(unix)]
    #[test]
    fn liveness_accepts_surviving_process() {
        let mut child = Command::new("sleep").arg("5").spawn().expect("spawn sleep");
        assert!(verify_spawn_liveness(&mut child).is_ok());
        let _ = child.kill();
        let _ = child.wait();
    }

    #[test]
    fn watch_poll_detaches_for_stale_generation() {
        let core = CoreRuntime::new(std::env::temp_dir().join("viasix-runtime-test"));
        // No session started: generation 0 with no child must detach, not exit.
        assert_eq!(core.watch_poll(core.generation()), WatchOutcome::Detached);
        // A generation from a superseded session also detaches quietly.
        assert_eq!(core.watch_poll(u64::MAX), WatchOutcome::Detached);
    }
}
