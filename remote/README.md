# Remote engine: Intiface Engine on a Raspberry Pi

This fork of Intiface Central can drive a headless Intiface Engine running on
another machine, typically a Raspberry Pi sitting near your devices. Central
(on Windows, Linux or Android) becomes a remote control panel: start and stop
the engine, see the connected client and devices, use the device control
panel, and edit device settings. Game clients connect to the Pi's address.

```
 game / client app ──ws:12345──► Raspberry Pi ◄──BLE / serial / USB── devices
                                 intiface-remote-daemon
 Intiface Central ───ws:12346──► (embeds intiface-engine 5.0.5)
```

## 1. Set up the Pi

Requirements: 64-bit Raspberry Pi OS Bullseye or newer (Pi 3, 4, 5, Zero 2 W),
with Bluetooth enabled.

Build the daemon on any x86_64 Linux machine with rustup, uv, git and make:

```sh
cd remote/intiface-remote-daemon
./scripts/build-pi.sh
```

Copy the binary and the `packaging` folder to the Pi and install:

```sh
scp target/aarch64-unknown-linux-gnu/release/intiface-remote-daemon \
    -r packaging pi@raspberrypi.local:~/
ssh pi@raspberrypi.local
sudo ./packaging/install.sh ./intiface-remote-daemon
```

The installer creates an `intiface` service user, generates an access token
in `/etc/intiface-remote/token`, and enables the `intiface-remote` systemd
service. It prints the address and token to enter in Central.

Alternatively, build directly on the Pi (slow, roughly 20-40 minutes on a
Pi 4): install Rust with rustup, `sudo apt install build-essential libudev-dev pkg-config`,
then `cargo build --release` in `remote/intiface-remote-daemon`.

Useful commands on the Pi:

```sh
sudo systemctl status intiface-remote
journalctl -u intiface-remote -f      # logs
sudo cat /etc/intiface-remote/token   # the access token
```

## 2. Install Central

- **Linux:** `flutter build linux --release`, then run
  `build/linux/x64/release/bundle/intiface_central`.
- **Windows:** on a Windows PC, `flutter build windows --release`, then run
  `build\windows\x64\runner\Release\intiface_central.exe`.
- **Android:** `flutter build apk --release` produces
  `build/app/outputs/flutter-apk/app-release.apk`. The fork installs as a
  separate app, **Intiface Remote** (`com.nonpolynomial.intiface_central.remote`),
  so it can sit alongside the official Intiface Central. Without a
  `android/key.properties` it is signed with the standard Android debug key,
  which is fine for sideloading on your own phone (allow installs from unknown
  sources). Sign future builds with the same key, or Android will refuse the
  update.

## 3. Point Central at the Pi

In Central, open **Settings > Remote Engine (Raspberry Pi)**:

1. Set **Remote Address**, e.g. `192.168.1.50` or `ws://raspberrypi.local:12346`.
2. Set **Access Token** to the token from the Pi.
3. Press **Test Connection**.
4. Turn on **Use Remote Engine**.

Then press Start as usual. Settings under the Server and Device Managers pages
(server name and port, Bluetooth, serial, Lovense dongles, gamepads, simulated
devices) are sent to the Pi on each start. Device managers that need a
desktop host are offered even when Central runs on a phone, since they run on
the Pi.

Game clients connect to `ws://<pi address>:<server port>` (12345 by default),
which the control panel shows while in remote mode.

## How it behaves

- **The engine lives on the Pi.** Closing Central, a phone going to sleep, or
  a network drop does not stop it. Pressing Start again reattaches and shows
  the current client and devices. Stop in Central stops the engine on the Pi.
  Tray > Quit only disconnects.
- **Headless start at boot.** The service runs with `--autostart`, so after a
  reboot the engine starts with the options Central last used. Remove the flag
  in `/etc/systemd/system/intiface-remote.service` to only start on demand.
- **One controller at a time.** Connecting from a second Central (say, your
  phone) takes over; the first one is told and disconnects.
- **Device settings sync both ways.** Central sends its device config on start.
  The Pi's copy is authoritative while connected, since that's where devices
  are discovered, and it is pushed to Central on connect and whenever a device
  connects. Edits made in Central (allow/deny, display names, message gaps,
  simulated devices, serial and websocket device entries) are applied live on
  the Pi.
- **Client server exposure.** If Central's "Listen on all network interfaces"
  is off, the Pi still listens on all interfaces, because clients of a
  headless Pi are on other machines. Run the daemon with
  `--keep-listen-address` to disable that.

## Security

The control port (12346) can start the engine and drive devices, so:

- It requires the access token on every connection (compared in constant
  time). Keep it private; regenerate it by deleting
  `/etc/intiface-remote/token` and rerunning the installer.
- Traffic is unencrypted websocket. Use it on a network you trust, or put it
  behind a VPN such as WireGuard or Tailscale. Don't forward the port to the
  internet.
- Central stores the token in its app preferences in plain text.

## Daemon options

```
intiface-remote-daemon [--listen 0.0.0.0:12346] [--token-file /etc/intiface-remote/token]
                       [--state-dir /var/lib/intiface-remote] [--autostart]
                       [--keep-listen-address]
```

`INTIFACE_REMOTE_TOKEN` overrides the token file. `RUST_LOG` sets log levels.

## Protocol

JSON text frames tagged by `type`; see
`intiface-remote-daemon/src/protocol.rs`. The first frame must be
`{"type":"hello","token":"…","protocol":1}`. Engine and backdoor messages are
carried verbatim in `raw` frames, so Central parses them exactly as it does
for the built-in engine.

## Tests

```sh
cd remote/intiface-remote-daemon
cargo test
uv venv && uv pip install websockets
.venv/bin/python tests/e2e.py target/debug/intiface-remote-daemon

# Central's provider against the real daemon:
cd ../..
INTIFACE_REMOTE_DAEMON=$PWD/remote/intiface-remote-daemon/target/debug/intiface-remote-daemon \
  flutter test test/bloc/engine/remote_engine_provider_test.dart
```
