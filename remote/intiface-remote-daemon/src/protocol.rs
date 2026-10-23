//! Wire protocol between Intiface Central (the controller) and this daemon.
//!
//! Every websocket text frame is one JSON object tagged by `type`. Engine
//! status messages and backdoor responses are relayed unchanged inside
//! `raw` frames, so Central's existing message parsing works as-is.

use intiface_engine::EngineOptionsExternal;
use serde::{Deserialize, Serialize};

/// Bump when either side changes incompatibly. Central refuses a daemon with
/// a different major protocol version.
pub const PROTOCOL_VERSION: u32 = 1;

#[derive(Debug, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ControllerMessage {
  /// Must be the first frame on every connection.
  Hello {
    token: String,
    protocol: u32,
    #[serde(default)]
    client_name: Option<String>,
  },
  /// Start the engine. If `options.user_device_config_json` is set, it
  /// replaces the daemon's stored user device config before starting.
  Start { options: RemoteEngineOptions },
  /// Stop the engine and wait for cleanup.
  Stop,
  /// A raw `IntifaceMessage` JSON string for the engine frontend channel.
  Engine { message: String },
  /// A raw Buttplug message string for the backdoor server (device panel).
  Backdoor { message: String },
  /// Replace the stored user device config; applied live if running.
  SetUserConfig { json: String },
  GetUserConfig,
  GetStatus,
  Ping,
}

#[derive(Debug, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum DaemonMessage {
  Welcome {
    protocol: u32,
    daemon_version: String,
    engine_version: String,
    hostname: String,
    running: bool,
  },
  /// An engine or backdoor message, exactly as the in-process engine would
  /// have delivered it to Central.
  Raw { message: String },
  Status { running: bool },
  UserConfig { json: String },
  Error { message: String },
  /// Sent to a controller that was replaced by a newer connection.
  Replaced,
  Pong,
}

impl DaemonMessage {
  pub fn to_json(&self) -> String {
    serde_json::to_string(self).expect("daemon messages always serialize")
  }
}

/// Serde mirror of `intiface_engine::EngineOptionsExternal` (which has no
/// serde derives). Field names match the Rust struct; missing fields take
/// the engine defaults.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct RemoteEngineOptions {
  pub device_config_json: Option<String>,
  pub user_device_config_json: Option<String>,
  pub user_device_config_path: Option<String>,
  pub server_name: String,
  pub websocket_listen_address: Option<String>,
  pub websocket_client_address: Option<String>,
  pub frontend_websocket_port: Option<u16>,
  pub frontend_in_process_channel: bool,
  pub max_ping_time: u32,
  pub use_bluetooth_le: bool,
  pub use_serial_port: bool,
  pub use_lovense_dongle_serial: bool,
  pub use_lovense_dongle_hid: bool,
  pub use_sdl_gamepad: bool,
  pub use_lovense_connect: bool,
  pub use_device_websocket_server: bool,
  pub use_simulated_devices: bool,
  pub device_websocket_server_port: Option<u16>,
  pub crash_main_thread: bool,
  pub crash_task_thread: bool,
  pub broadcast_server_mdns: bool,
  pub mdns_suffix: Option<String>,
  pub repeater_mode: bool,
  pub repeater_local_port: Option<u16>,
  pub repeater_remote_address: Option<String>,
  pub rest_api_port: Option<u16>,
  pub emit_output_observations: bool,
}

impl From<RemoteEngineOptions> for EngineOptionsExternal {
  fn from(o: RemoteEngineOptions) -> Self {
    EngineOptionsExternal {
      device_config_json: o.device_config_json,
      user_device_config_json: o.user_device_config_json,
      user_device_config_path: o.user_device_config_path,
      server_name: o.server_name,
      websocket_listen_address: o.websocket_listen_address,
      websocket_client_address: o.websocket_client_address,
      frontend_websocket_port: o.frontend_websocket_port,
      frontend_in_process_channel: o.frontend_in_process_channel,
      max_ping_time: o.max_ping_time,
      use_bluetooth_le: o.use_bluetooth_le,
      use_serial_port: o.use_serial_port,
      use_lovense_dongle_serial: o.use_lovense_dongle_serial,
      use_lovense_dongle_hid: o.use_lovense_dongle_hid,
      use_sdl_gamepad: o.use_sdl_gamepad,
      use_lovense_connect: o.use_lovense_connect,
      use_device_websocket_server: o.use_device_websocket_server,
      use_simulated_devices: o.use_simulated_devices,
      device_websocket_server_port: o.device_websocket_server_port,
      crash_main_thread: o.crash_main_thread,
      crash_task_thread: o.crash_task_thread,
      broadcast_server_mdns: o.broadcast_server_mdns,
      mdns_suffix: o.mdns_suffix,
      repeater_mode: o.repeater_mode,
      repeater_local_port: o.repeater_local_port,
      repeater_remote_address: o.repeater_remote_address,
      rest_api_port: o.rest_api_port,
      emit_output_observations: o.emit_output_observations,
    }
  }
}

#[cfg(test)]
mod tests {
  use super::*;

  #[test]
  fn parses_controller_frames() {
    let m: ControllerMessage =
      serde_json::from_str(r#"{"type":"hello","token":"t","protocol":1}"#).unwrap();
    assert!(matches!(m, ControllerMessage::Hello { protocol: 1, .. }));
    let m: ControllerMessage = serde_json::from_str(r#"{"type":"stop"}"#).unwrap();
    assert!(matches!(m, ControllerMessage::Stop));
    let m: ControllerMessage = serde_json::from_str(
      r#"{"type":"start","options":{"server_name":"Pi","use_bluetooth_le":true}}"#,
    )
    .unwrap();
    match m {
      ControllerMessage::Start { options } => {
        assert_eq!(options.server_name, "Pi");
        assert!(options.use_bluetooth_le);
        assert!(!options.use_serial_port);
      }
      _ => panic!(),
    }
  }

  #[test]
  fn serializes_daemon_frames() {
    let json = DaemonMessage::Raw {
      message: "{\"EngineStarted\":{}}".into(),
    }
    .to_json();
    assert_eq!(json, r#"{"type":"raw","message":"{\"EngineStarted\":{}}"}"#);
    assert_eq!(DaemonMessage::Pong.to_json(), r#"{"type":"pong"}"#);
  }
}
