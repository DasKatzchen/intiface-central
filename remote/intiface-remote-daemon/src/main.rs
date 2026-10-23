//! intiface-remote-daemon: runs Intiface Engine headless (e.g. on a
//! Raspberry Pi) and lets a modified Intiface Central control it over a
//! token-authenticated websocket.

mod host;
mod protocol;

use anyhow::{Context, Result, bail};
use argh::FromArgs;
use futures::{SinkExt, StreamExt};
use host::{Host, HostConfig};
use protocol::{ControllerMessage, DaemonMessage, PROTOCOL_VERSION};
use std::{net::SocketAddr, path::PathBuf, sync::Arc, time::Duration};
use tokio::{
  net::{TcpListener, TcpStream},
  sync::{broadcast, watch},
};
use tokio_tungstenite::tungstenite::Message;
use tracing::{error, info, warn};

const ENGINE_VERSION: &str = "5.0.5";
const HELLO_TIMEOUT: Duration = Duration::from_secs(10);
const PING_INTERVAL: Duration = Duration::from_secs(20);

/// Headless Intiface Engine host for remote control by Intiface Central.
#[derive(FromArgs)]
struct Args {
  /// address for the control websocket (default 0.0.0.0:12346)
  #[argh(option, default = "\"0.0.0.0:12346\".parse().unwrap()")]
  listen: SocketAddr,
  /// file containing the shared access token (default
  /// /etc/intiface-remote/token); the INTIFACE_REMOTE_TOKEN environment
  /// variable takes precedence
  #[argh(option, default = "PathBuf::from(\"/etc/intiface-remote/token\")")]
  token_file: PathBuf,
  /// directory for the user device config and last engine options
  /// (default /var/lib/intiface-remote)
  #[argh(option, default = "PathBuf::from(\"/var/lib/intiface-remote\")")]
  state_dir: PathBuf,
  /// start the engine at boot with the last options Central used
  #[argh(switch)]
  autostart: bool,
  /// keep a loopback Buttplug server address as sent by Central instead of
  /// rewriting it to 0.0.0.0
  #[argh(switch)]
  keep_listen_address: bool,
}

fn load_token(args: &Args) -> Result<String> {
  let token = match std::env::var("INTIFACE_REMOTE_TOKEN") {
    Ok(t) => t,
    Err(_) => std::fs::read_to_string(&args.token_file)
      .with_context(|| format!("Could not read token file {}", args.token_file.display()))?,
  };
  let token = token.trim().to_owned();
  if token.len() < 16 {
    bail!("Access token must be at least 16 characters");
  }
  Ok(token)
}

fn token_matches(expected: &str, given: &str) -> bool {
  let (a, b) = (expected.as_bytes(), given.as_bytes());
  if a.len() != b.len() {
    return false;
  }
  a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

fn hostname() -> String {
  std::fs::read_to_string("/etc/hostname")
    .map(|s| s.trim().to_owned())
    .unwrap_or_else(|_| "intiface-remote".to_owned())
}

#[tokio::main]
async fn main() -> Result<()> {
  tracing_subscriber::fmt()
    .with_env_filter(
      tracing_subscriber::EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| "info,buttplug=info,intiface_engine=info".into()),
    )
    .init();

  let args: Args = argh::from_env();
  let token = Arc::new(load_token(&args)?);
  std::fs::create_dir_all(&args.state_dir)
    .with_context(|| format!("Could not create {}", args.state_dir.display()))?;

  let host = Host::new(HostConfig {
    state_dir: args.state_dir.clone(),
    expose_server: !args.keep_listen_address,
  });

  if args.autostart {
    match host.last_options() {
      Some(options) => match host.start(options).await {
        Ok(()) => info!("Autostarted engine with last options"),
        Err(e) => error!("Autostart failed: {e:#}"),
      },
      None => info!("Autostart requested but Central has never started the engine yet"),
    }
  }

  let listener = TcpListener::bind(args.listen)
    .await
    .with_context(|| format!("Could not bind {}", args.listen))?;
  info!("Listening for Intiface Central on ws://{}", args.listen);

  // Only one controller at a time; a new authenticated connection replaces
  // the previous one (e.g. switching from the PC to the phone).
  let (controller_tx, _) = watch::channel(0u64);
  let controller_tx = Arc::new(controller_tx);
  let mut next_id = 0u64;

  loop {
    tokio::select! {
      accepted = listener.accept() => {
        let (stream, peer) = match accepted {
          Ok(a) => a,
          Err(e) => { warn!("Accept failed: {e}"); continue; }
        };
        next_id += 1;
        let (host, token, ctl) = (host.clone(), token.clone(), controller_tx.clone());
        let id = next_id;
        tokio::spawn(async move {
          if let Err(e) = handle_connection(stream, peer, id, host, token, ctl).await {
            info!("Controller {peer} closed: {e:#}");
          }
        });
      }
      _ = shutdown_signal() => {
        info!("Shutting down");
        if let Err(e) = host.stop().await {
          error!("Engine stop failed: {e:#}");
        }
        return Ok(());
      }
    }
  }
}

async fn shutdown_signal() {
  let ctrl_c = tokio::signal::ctrl_c();
  #[cfg(unix)]
  {
    let mut term =
      tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()).unwrap();
    tokio::select! { _ = ctrl_c => {}, _ = term.recv() => {} }
  }
  #[cfg(not(unix))]
  let _ = ctrl_c.await;
}

async fn handle_connection(
  stream: TcpStream,
  peer: SocketAddr,
  id: u64,
  host: Arc<Host>,
  token: Arc<String>,
  controller: Arc<watch::Sender<u64>>,
) -> Result<()> {
  let _ = stream.set_nodelay(true);
  let ws = tokio_tungstenite::accept_async(stream).await?;
  let (mut tx, mut rx) = ws.split();

  // Authenticate.
  let hello = tokio::time::timeout(HELLO_TIMEOUT, rx.next())
    .await
    .context("No hello received")?
    .context("Connection closed before hello")??;
  let client_name = match hello {
    Message::Text(t) => match serde_json::from_str::<ControllerMessage>(&t) {
      Ok(ControllerMessage::Hello {
        token: given,
        protocol,
        client_name,
      }) => {
        if !token_matches(&token, &given) {
          tx.send(text(DaemonMessage::Error {
            message: "Invalid access token".into(),
          }))
          .await?;
          bail!("rejected {peer}: bad token");
        }
        if protocol != PROTOCOL_VERSION {
          tx.send(text(DaemonMessage::Error {
            message: format!(
              "Protocol mismatch: daemon speaks {PROTOCOL_VERSION}, Central speaks {protocol}"
            ),
          }))
          .await?;
          bail!("rejected {peer}: protocol {protocol}");
        }
        client_name.unwrap_or_else(|| "unknown".into())
      }
      _ => bail!("rejected {peer}: first frame was not hello"),
    },
    _ => bail!("rejected {peer}: first frame was not text"),
  };
  info!("Controller {client_name} connected from {peer}");

  // Subscribe before taking over so nothing between replay and live is lost.
  let mut out = host.subscribe();
  controller.send_replace(id);
  let mut current = controller.subscribe();

  let running = host.is_running().await;
  tx.send(text(DaemonMessage::Welcome {
    protocol: PROTOCOL_VERSION,
    daemon_version: env!("CARGO_PKG_VERSION").into(),
    engine_version: ENGINE_VERSION.into(),
    hostname: hostname(),
    running,
  }))
  .await?;
  if let Some(json) = host.current_user_config() {
    tx.send(text(DaemonMessage::UserConfig { json })).await?;
  }
  if running {
    for message in host.replay_messages() {
      tx.send(text(DaemonMessage::Raw { message })).await?;
    }
  }

  let mut ping = tokio::time::interval(PING_INTERVAL);
  ping.tick().await;
  loop {
    tokio::select! {
      incoming = rx.next() => {
        let Some(frame) = incoming else { return Ok(()) };
        match frame? {
          Message::Text(t) => {
            if let Some(reply) = handle_message(&host, &t).await {
              tx.send(text(reply)).await?;
            }
          }
          Message::Close(_) => return Ok(()),
          _ => {}
        }
      }
      msg = out.recv() => match msg {
        Ok(json) => tx.send(Message::text(json)).await?,
        Err(broadcast::error::RecvError::Lagged(n)) => {
          // Usually output observations from a busy device; safe to drop.
          warn!("Controller lagged, dropped {n} messages");
        }
        Err(broadcast::error::RecvError::Closed) => return Ok(()),
      },
      _ = current.changed() => {
        if *current.borrow() != id {
          let _ = tx.send(text(DaemonMessage::Replaced)).await;
          let _ = tx.close().await;
          bail!("replaced by a newer controller");
        }
      }
      _ = ping.tick() => tx.send(Message::Ping(Vec::new().into())).await?,
    }
  }
}

fn text(msg: DaemonMessage) -> Message {
  Message::text(msg.to_json())
}

async fn handle_message(host: &Arc<Host>, raw: &str) -> Option<DaemonMessage> {
  let msg = match serde_json::from_str::<ControllerMessage>(raw) {
    Ok(m) => m,
    Err(e) => {
      return Some(DaemonMessage::Error {
        message: format!("Unparseable message: {e}"),
      });
    }
  };
  let result = match msg {
    ControllerMessage::Hello { .. } => Ok(None),
    ControllerMessage::Start { options } => host.start(options).await.map(|_| None),
    ControllerMessage::Stop => host.stop().await.map(|_| None),
    ControllerMessage::Engine { message } => host.send_engine_message(&message).map(|_| None),
    ControllerMessage::Backdoor { message } => {
      host.send_backdoor_message(message);
      Ok(None)
    }
    ControllerMessage::SetUserConfig { json } => host.set_user_config(&json).map(|_| None),
    ControllerMessage::GetUserConfig => Ok(
      host
        .current_user_config()
        .map(|json| DaemonMessage::UserConfig { json }),
    ),
    ControllerMessage::GetStatus => Ok(Some(DaemonMessage::Status {
      running: host.is_running().await,
    })),
    ControllerMessage::Ping => Ok(Some(DaemonMessage::Pong)),
  };
  match result {
    Ok(reply) => reply,
    Err(e) => {
      error!("{e:#}");
      Some(DaemonMessage::Error {
        message: format!("{e:#}"),
      })
    }
  }
}

#[cfg(test)]
mod tests {
  use super::token_matches;

  #[test]
  fn token_compare() {
    assert!(token_matches("abcdefghijklmnop", "abcdefghijklmnop"));
    assert!(!token_matches("abcdefghijklmnop", "abcdefghijklmnoq"));
    assert!(!token_matches("abcdefghijklmnop", "abc"));
  }
}
