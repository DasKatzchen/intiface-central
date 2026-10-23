//! Owns the embedded Intiface Engine: start/stop, relaying its messages to
//! the controller, the backdoor channel, and the persisted user device config.

use crate::protocol::{DaemonMessage, RemoteEngineOptions};
use anyhow::{Context, Result, anyhow, bail};
use async_trait::async_trait;
use buttplug_server_device_config::{
  DeviceConfigurationManager, load_protocol_configs, save_user_config,
};
use futures::{StreamExt, pin_mut};
use intiface_engine::{
  EngineMessage, EngineOptionsExternal, Frontend, IntifaceEngine, IntifaceError, IntifaceMessage,
};
use std::{
  collections::BTreeMap,
  path::PathBuf,
  sync::{Arc, Mutex as StdMutex, RwLock},
  time::Duration,
};
use tokio::{
  sync::{Mutex, Notify, broadcast},
  task::JoinHandle,
};
use tokio_util::sync::CancellationToken;
use tracing::{error, info, warn};

const STOP_TIMEOUT: Duration = Duration::from_secs(15);
const USER_CONFIG_FILE: &str = "buttplug-user-device-config-v5.json";
const LAST_OPTIONS_FILE: &str = "last-engine-options.json";

/// Messages needed to bring a newly connected controller up to date with an
/// engine that is already running.
#[derive(Default)]
struct Snapshot {
  started: bool,
  server_created: Option<String>,
  client: Option<String>,
  devices: BTreeMap<u32, String>,
}

impl Snapshot {
  fn record(&mut self, msg: &EngineMessage, json: &str) {
    match msg {
      EngineMessage::EngineStarted {} => {
        *self = Snapshot {
          started: true,
          ..Default::default()
        }
      }
      EngineMessage::EngineServerCreated { .. } => self.server_created = Some(json.to_owned()),
      EngineMessage::ClientConnected { .. } => self.client = Some(json.to_owned()),
      EngineMessage::ClientDisconnected {} => self.client = None,
      EngineMessage::DeviceConnected { index, .. } => {
        self.devices.insert(*index, json.to_owned());
      }
      EngineMessage::DeviceDisconnected { index } => {
        self.devices.remove(index);
      }
      EngineMessage::EngineStopped {} => *self = Snapshot::default(),
      _ => {}
    }
  }

  fn replay(&self) -> Vec<String> {
    if !self.started {
      return vec![];
    }
    let mut out = vec![serde_json::to_string(&EngineMessage::EngineStarted {}).unwrap()];
    out.extend(self.server_created.iter().cloned());
    out.extend(self.client.iter().cloned());
    out.extend(self.devices.values().cloned());
    out
  }
}

pub struct HostConfig {
  pub state_dir: PathBuf,
  /// Rewrite a loopback Buttplug listen address to 0.0.0.0, since clients
  /// of a headless Pi are almost always on other machines.
  pub expose_server: bool,
}

struct Running {
  engine: Arc<IntifaceEngine>,
  task: JoinHandle<()>,
}

pub struct Host {
  cfg: HostConfig,
  out: broadcast::Sender<String>,
  engine_in: Arc<broadcast::Sender<IntifaceMessage>>,
  backdoor_in: broadcast::Sender<String>,
  running: Mutex<Option<Running>>,
  snapshot: StdMutex<Snapshot>,
  dcm: RwLock<Option<Arc<DeviceConfigurationManager>>>,
}

impl Host {
  pub fn new(cfg: HostConfig) -> Arc<Self> {
    Arc::new(Self {
      cfg,
      out: broadcast::channel(1024).0,
      engine_in: Arc::new(broadcast::channel(64).0),
      backdoor_in: broadcast::channel(256).0,
      running: Mutex::new(None),
      snapshot: StdMutex::new(Snapshot::default()),
      dcm: RwLock::new(None),
    })
  }

  pub fn subscribe(&self) -> broadcast::Receiver<String> {
    self.out.subscribe()
  }

  pub fn emit(&self, msg: DaemonMessage) {
    let _ = self.out.send(msg.to_json());
  }

  pub async fn is_running(&self) -> bool {
    match &*self.running.lock().await {
      Some(r) => !r.task.is_finished(),
      None => false,
    }
  }

  pub fn replay_messages(&self) -> Vec<String> {
    self.snapshot.lock().unwrap().replay()
  }

  fn path(&self, name: &str) -> PathBuf {
    self.cfg.state_dir.join(name)
  }

  pub fn stored_user_config(&self) -> Option<String> {
    std::fs::read_to_string(self.path(USER_CONFIG_FILE)).ok()
  }

  fn store_user_config(&self, json: &str) {
    if let Err(e) = std::fs::write(self.path(USER_CONFIG_FILE), json) {
      error!("Could not save user device config: {e}");
    }
  }

  /// Current user config: from the live engine if running, else from disk.
  pub fn current_user_config(&self) -> Option<String> {
    if let Some(dcm) = &*self.dcm.read().unwrap() {
      match save_user_config(dcm) {
        Ok(json) => return Some(json),
        Err(e) => warn!("Could not serialize live user config: {e:?}"),
      }
    }
    self.stored_user_config()
  }

  /// Save the live config to disk and push it to the controller. Called after
  /// device connects, which can add new user device definitions.
  fn sync_user_config(&self) {
    if let Some(json) = self.current_user_config() {
      self.store_user_config(&json);
      self.emit(DaemonMessage::UserConfig { json });
    }
  }

  pub fn last_options(&self) -> Option<RemoteEngineOptions> {
    let s = std::fs::read_to_string(self.path(LAST_OPTIONS_FILE)).ok()?;
    serde_json::from_str(&s).ok()
  }

  /// Replace the user device config. Validated first; applied in place if
  /// the engine is running so allow/deny, names and message gaps take effect
  /// without a restart.
  pub fn set_user_config(&self, json: &str) -> Result<()> {
    let parsed = load_protocol_configs(&None, &Some(json.to_owned()), false)
      .map_err(|e| anyhow!("Invalid user device config: {e:?}"))?
      .finish()
      .map_err(|e| anyhow!("Invalid user device config: {e:?}"))?;
    self.store_user_config(json);
    if let Some(live) = &*self.dcm.read().unwrap() {
      // Simulated devices first: removing one also drops its user device
      // definition, so definitions must be written afterwards.
      for sim in live.simulated_devices() {
        live.remove_simulated_device(&sim.address);
      }
      for sim in parsed.simulated_devices() {
        if let Err(e) = live.add_simulated_device(sim) {
          warn!("Skipping simulated device: {e:?}");
        }
      }
      let defs = live.user_device_definitions();
      defs.clear();
      for kv in parsed.user_device_definitions().iter() {
        defs.insert(kv.key().clone(), kv.value().clone());
      }
      let specs = live.user_communication_specifiers();
      specs.clear();
      for kv in parsed.user_communication_specifiers().iter() {
        specs.insert(kv.key().clone(), kv.value().clone());
      }
      info!("Applied updated user device config to running engine");
    }
    Ok(())
  }

  pub async fn start(self: &Arc<Self>, mut options: RemoteEngineOptions) -> Result<()> {
    let mut running = self.running.lock().await;
    if let Some(r) = &*running
      && !r.task.is_finished()
    {
      bail!("Engine is already running");
    }

    // Central sends its user config with every start; the Pi keeps its own
    // copy so it can also start headless (autostart) with the same config.
    if let Some(json) = options.user_device_config_json.take() {
      self.store_user_config(&json);
    }
    let mut persisted = options.clone();
    persisted.device_config_json = None;
    if let Err(e) = std::fs::write(
      self.path(LAST_OPTIONS_FILE),
      serde_json::to_string_pretty(&persisted)?,
    ) {
      warn!("Could not save last engine options: {e}");
    }

    let dcm = Arc::new(
      load_protocol_configs(&options.device_config_json, &self.stored_user_config(), false)
        .and_then(|mut b| b.finish())
        .map_err(|e| anyhow!("Could not load device configuration: {e:?}"))?,
    );
    *self.dcm.write().unwrap() = Some(dcm.clone());

    options.user_device_config_path = None;
    options.frontend_websocket_port = None;
    options.frontend_in_process_channel = true;
    if self.cfg.expose_server {
      options.websocket_listen_address = options
        .websocket_listen_address
        .map(|addr| expose_listen_address(&addr));
    }
    info!("Starting engine with options: {options:?}");
    let engine_options = EngineOptionsExternal::from(options).into();

    let engine = Arc::new(IntifaceEngine::default());
    let created = Arc::new(Notify::new());
    let frontend = Arc::new(DaemonFrontend {
      host: Arc::downgrade(self),
      engine_in: self.engine_in.clone(),
      created: created.clone(),
      disconnect: Arc::new(Notify::new()),
    });
    let host = self.clone();
    let run_engine = engine.clone();
    let task = tokio::spawn(async move {
      let cancel = CancellationToken::new();
      let backdoor = tokio::spawn(backdoor_loop(
        host.clone(),
        run_engine.clone(),
        created,
        cancel.clone(),
      ));
      if let Err(e) = run_engine
        .run(&engine_options, Some(frontend), &Some(dcm))
        .await
      {
        error!("Engine exited with error: {e:?}");
        host.emit(DaemonMessage::Error {
          message: format!("Engine error: {e:?}"),
        });
      }
      cancel.cancel();
      let _ = backdoor.await;
      host.sync_user_config();
      *host.dcm.write().unwrap() = None;
      *host.snapshot.lock().unwrap() = Snapshot::default();
      host.emit(DaemonMessage::Status { running: false });
      info!("Engine stopped");
    });
    *running = Some(Running { engine, task });
    self.emit(DaemonMessage::Status { running: true });
    Ok(())
  }

  pub async fn stop(&self) -> Result<()> {
    let Some(Running { engine, task }) = self.running.lock().await.take() else {
      return Ok(());
    };
    engine.stop();
    tokio::time::timeout(STOP_TIMEOUT, task)
      .await
      .context("Engine did not stop in time")?
      .context("Engine task panicked")?;
    Ok(())
  }

  pub fn send_engine_message(&self, raw: &str) -> Result<()> {
    let msg: IntifaceMessage = serde_json::from_str(raw).context("Invalid engine message")?;
    let _ = self.engine_in.send(msg);
    Ok(())
  }

  pub fn send_backdoor_message(&self, raw: String) {
    let _ = self.backdoor_in.send(raw);
  }
}

fn expose_listen_address(addr: &str) -> String {
  match addr.rsplit_once(':') {
    Some(("127.0.0.1" | "localhost" | "[::1]", port)) => format!("0.0.0.0:{port}"),
    _ => addr.to_owned(),
  }
}

async fn backdoor_loop(
  host: Arc<Host>,
  engine: Arc<IntifaceEngine>,
  created: Arc<Notify>,
  cancel: CancellationToken,
) {
  let mut incoming = host.backdoor_in.subscribe();
  tokio::select! {
    _ = created.notified() => {}
    _ = cancel.cancelled() => return,
  }
  let Some(server) = engine.backdoor_server() else {
    error!("Engine has no backdoor server; device control panel unavailable");
    return;
  };
  let events = server.event_stream();
  pin_mut!(events);
  loop {
    tokio::select! {
      msg = incoming.recv() => match msg {
        Ok(m) => server.clone().parse_message(&m).await,
        Err(broadcast::error::RecvError::Lagged(n)) => warn!("Dropped {n} backdoor messages"),
        Err(_) => break,
      },
      out = events.next() => match out {
        Some(m) => host.emit(DaemonMessage::Raw { message: m }),
        None => break,
      },
      _ = cancel.cancelled() => break,
    }
  }
}

struct DaemonFrontend {
  host: std::sync::Weak<Host>,
  engine_in: Arc<broadcast::Sender<IntifaceMessage>>,
  created: Arc<Notify>,
  disconnect: Arc<Notify>,
}

#[async_trait]
impl Frontend for DaemonFrontend {
  async fn send(&self, msg: EngineMessage) {
    let Some(host) = self.host.upgrade() else {
      return;
    };
    let json = serde_json::to_string(&msg).unwrap();
    host.snapshot.lock().unwrap().record(&msg, &json);
    if matches!(msg, EngineMessage::EngineServerCreated { .. }) {
      // notify_one stores a permit, so the backdoor task cannot miss it.
      self.created.notify_one();
    }
    host.emit(DaemonMessage::Raw { message: json });
    if matches!(msg, EngineMessage::DeviceConnected { .. }) {
      host.sync_user_config();
    }
  }
  async fn connect(&self) -> Result<(), IntifaceError> {
    Ok(())
  }
  fn disconnect_notifier(&self) -> Arc<Notify> {
    self.disconnect.clone()
  }
  fn disconnect(&self) {
    self.disconnect.notify_waiters();
  }
  fn event_stream(&self) -> broadcast::Receiver<IntifaceMessage> {
    self.engine_in.subscribe()
  }
}

#[cfg(test)]
mod tests {
  use super::*;

  #[test]
  fn exposes_loopback_only() {
    assert_eq!(expose_listen_address("127.0.0.1:12345"), "0.0.0.0:12345");
    assert_eq!(expose_listen_address("localhost:1"), "0.0.0.0:1");
    assert_eq!(expose_listen_address("192.168.1.5:12345"), "192.168.1.5:12345");
  }

  #[test]
  fn snapshot_replays_current_state() {
    let mut s = Snapshot::default();
    let msgs = [
      EngineMessage::EngineStarted {},
      EngineMessage::EngineServerCreated {
        service_type: None,
        instance_name: None,
        port: None,
        txt_records: None,
      },
      EngineMessage::ClientConnected {
        client_name: "Game".into(),
      },
      EngineMessage::DeviceDisconnected { index: 9 },
    ];
    for m in &msgs {
      s.record(m, &serde_json::to_string(m).unwrap());
    }
    let r = s.replay();
    assert_eq!(r.len(), 3);
    assert!(r[2].contains("Game"));
    s.record(&EngineMessage::ClientDisconnected {}, "");
    assert_eq!(s.replay().len(), 2);
    s.record(&EngineMessage::EngineStopped {}, "");
    assert!(s.replay().is_empty());
  }
}
