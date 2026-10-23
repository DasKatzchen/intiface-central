// Engine provider that drives a headless Intiface Engine on another machine
// (e.g. a Raspberry Pi running intiface-remote-daemon) over a websocket.
//
// The daemon relays engine and backdoor messages unchanged inside `raw`
// frames, so EngineRepository parses them exactly as it does for the
// in-process engine.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:intiface_central/bloc/engine/engine_provider.dart';
import 'package:intiface_central/src/rust/api/runtime.dart';
import 'package:loggy/loggy.dart';

/// Must match PROTOCOL_VERSION in remote/intiface-remote-daemon/src/protocol.rs.
const int remoteEngineProtocolVersion = 1;
const int remoteEngineDefaultPort = 12346;
const Duration _connectTimeout = Duration(seconds: 10);
const Duration _stopTimeout = Duration(seconds: 20);

class RemoteEngineConnectionInfo {
  final String address;
  final String token;

  const RemoteEngineConnectionInfo({required this.address, required this.token});

  /// Accepts "192.168.1.50", "pi.local:12346" or a full ws:// / wss:// URL.
  Uri get uri => normalizeRemoteEngineAddress(address);
}

Uri normalizeRemoteEngineAddress(String address) {
  var trimmed = address.trim();
  if (trimmed.isEmpty) {
    throw const FormatException("No remote engine address set");
  }
  if (!trimmed.contains("://")) {
    trimmed = "ws://$trimmed";
  }
  var uri = Uri.parse(trimmed);
  if (uri.scheme != "ws" && uri.scheme != "wss") {
    throw FormatException("Remote engine address must use ws:// or wss://, got ${uri.scheme}://");
  }
  if (uri.host.isEmpty) {
    throw const FormatException("Remote engine address has no host");
  }
  if (!uri.hasPort) {
    uri = uri.replace(port: remoteEngineDefaultPort);
  }
  return uri;
}

class RemoteEngineWelcome {
  final String hostname;
  final String daemonVersion;
  final String engineVersion;
  final bool running;

  RemoteEngineWelcome.fromJson(Map<String, dynamic> json)
    : hostname = json["hostname"] as String? ?? "",
      daemonVersion = json["daemon_version"] as String? ?? "",
      engineVersion = json["engine_version"] as String? ?? "",
      running = json["running"] as bool? ?? false;
}

/// Serializes engine options for the daemon (snake_case, matching the Rust
/// EngineOptionsExternal field names).
Map<String, dynamic> engineOptionsToRemoteJson(EngineOptionsExternal o) => {
  "device_config_json": o.deviceConfigJson,
  "user_device_config_json": o.userDeviceConfigJson,
  "server_name": o.serverName,
  "websocket_listen_address": o.websocketListenAddress,
  "websocket_client_address": o.websocketClientAddress,
  "max_ping_time": o.maxPingTime,
  "use_bluetooth_le": o.useBluetoothLe,
  "use_serial_port": o.useSerialPort,
  "use_lovense_dongle_serial": o.useLovenseDongleSerial,
  "use_lovense_dongle_hid": o.useLovenseDongleHid,
  "use_sdl_gamepad": o.useSdlGamepad,
  "use_lovense_connect": o.useLovenseConnect,
  "use_device_websocket_server": o.useDeviceWebsocketServer,
  "use_simulated_devices": o.useSimulatedDevices,
  "device_websocket_server_port": o.deviceWebsocketServerPort,
  "crash_main_thread": false,
  "crash_task_thread": false,
  "broadcast_server_mdns": o.broadcastServerMdns,
  "mdns_suffix": o.mdnsSuffix,
  "repeater_mode": o.repeaterMode,
  "repeater_local_port": o.repeaterLocalPort,
  "repeater_remote_address": o.repeaterRemoteAddress,
  "rest_api_port": o.restApiPort,
  "emit_output_observations": o.emitOutputObservations,
};

typedef WebSocketConnector = Future<WebSocket> Function(Uri uri);

Future<WebSocket> _defaultConnector(Uri uri) async {
  var socket = await WebSocket.connect(uri.toString()).timeout(_connectTimeout);
  socket.pingInterval = const Duration(seconds: 15);
  return socket;
}

/// Opens a connection, authenticates, and returns the daemon's welcome.
/// Throws [EngineProviderStartException] with a readable reason on failure.
/// The returned socket's first frame (the welcome) has been consumed; the
/// rest are delivered through [frames].
class _RemoteSession {
  final WebSocket socket;
  final RemoteEngineWelcome welcome;
  final Stream<Map<String, dynamic>> frames;

  _RemoteSession(this.socket, this.welcome, this.frames);

  static Future<_RemoteSession> open(RemoteEngineConnectionInfo info, WebSocketConnector connect) async {
    Uri uri;
    try {
      uri = info.uri;
    } on FormatException catch (e) {
      throw EngineProviderStartException(e.message);
    }
    WebSocket socket;
    try {
      socket = await connect(uri);
    } catch (e) {
      throw EngineProviderStartException(
        "Could not reach the remote engine at $uri. Check that the Pi is on and intiface-remote is running. ($e)",
      );
    }
    // One subscription for the whole connection: the first frame resolves the
    // handshake, everything after is buffered until the provider listens, so
    // replayed state sent right after the welcome is never dropped.
    var welcomeFrame = Completer<Map<String, dynamic>>();
    var frames = StreamController<Map<String, dynamic>>();
    socket.listen(
      (data) {
        if (data is! String) return;
        Map<String, dynamic> frame;
        try {
          frame = jsonDecode(data) as Map<String, dynamic>;
        } catch (e) {
          logError("Unparseable frame from remote engine: $data");
          return;
        }
        if (!welcomeFrame.isCompleted) {
          welcomeFrame.complete(frame);
        } else {
          frames.add(frame);
        }
      },
      onError: (Object e) {
        if (!welcomeFrame.isCompleted) welcomeFrame.completeError(e);
        frames.addError(e);
      },
      onDone: () {
        if (!welcomeFrame.isCompleted) {
          welcomeFrame.completeError(StateError("connection closed"));
        }
        frames.close();
      },
    );
    socket.add(
      jsonEncode({
        "type": "hello",
        "token": info.token.trim(),
        "protocol": remoteEngineProtocolVersion,
        "client_name": "Intiface Central (${Platform.operatingSystem})",
      }),
    );
    Map<String, dynamic> first;
    try {
      first = await welcomeFrame.future.timeout(_connectTimeout);
    } catch (e) {
      await socket.close();
      throw EngineProviderStartException("Remote engine did not answer the handshake ($e)");
    }
    if (first["type"] == "error") {
      await socket.close();
      throw EngineProviderStartException("Remote engine refused the connection: ${first["message"]}");
    }
    if (first["type"] != "welcome") {
      await socket.close();
      throw EngineProviderStartException("Unexpected handshake reply from remote engine: $first");
    }
    return _RemoteSession(socket, RemoteEngineWelcome.fromJson(first), frames.stream);
  }
}

class RemoteEngineProvider implements EngineProvider {
  RemoteEngineProvider({required RemoteEngineConnectionInfo Function() connectionInfo, WebSocketConnector? connector})
    : _connectionInfo = connectionInfo,
      _connect = connector ?? _defaultConnector;

  final RemoteEngineConnectionInfo Function() _connectionInfo;
  final WebSocketConnector _connect;

  _RemoteSession? _session;
  StreamSubscription<Map<String, dynamic>>? _subscription;
  StreamController<String> _rawStream = StreamController();
  final StreamController<String> _userConfigStream = StreamController.broadcast();

  bool _engineStarted = false;
  bool _closingDeliberately = false;
  Completer<void>? _stopped;

  /// User device config JSON pushed by the daemon (at connect, and whenever a
  /// device connects on the Pi). The Pi's copy is authoritative while
  /// connected.
  Stream<String> get userConfigStream => _userConfigStream.stream;

  bool get isConnected => _session != null;

  /// Connects, authenticates and closes again; used by the settings page.
  static Future<RemoteEngineWelcome> testConnection(
    RemoteEngineConnectionInfo info, {
    WebSocketConnector? connector,
  }) async {
    var session = await _RemoteSession.open(info, connector ?? _defaultConnector);
    await session.socket.close();
    return session.welcome;
  }

  @override
  Future<void> start({required EngineOptionsExternal options}) async {
    await _closeSession();
    // Not awaited: close() on a never-listened stream only resolves on listen.
    unawaited(_rawStream.close());
    _rawStream = StreamController();
    _engineStarted = false;
    _closingDeliberately = false;

    var info = _connectionInfo();
    var session = await _RemoteSession.open(info, _connect);
    _session = session;
    _subscription = session.frames.listen(
      _onFrame,
      onDone: _onDisconnected,
      onError: (e) => logError("Remote engine connection error: $e"),
    );

    var host = session.welcome.hostname;
    _log(
      "info",
      "Connected to remote engine on $host (daemon ${session.welcome.daemonVersion}, engine ${session.welcome.engineVersion})",
    );
    if (session.welcome.running) {
      // Attach: the daemon replays EngineStarted, the server, the client and
      // devices, so the UI catches up without restarting anything.
      _log("info", "Engine already running on $host, attaching to it");
    } else {
      _log("info", "Starting engine on $host");
      _sendFrame({"type": "start", "options": engineOptionsToRemoteJson(options)});
    }
  }

  void _onFrame(Map<String, dynamic> frame) {
    switch (frame["type"]) {
      case "raw":
        var message = frame["message"] as String;
        if (message.startsWith('{"EngineStarted"')) {
          _engineStarted = true;
        }
        _addRaw(message);
      case "user_config":
        _userConfigStream.add(frame["json"] as String);
      case "status":
        if (frame["running"] == false) {
          _engineStarted = false;
          _stopped?.complete();
          _stopped = null;
        }
      case "error":
        var message = frame["message"] as String? ?? "Unknown remote engine error";
        _addRaw(
          jsonEncode({
            "EngineError": {"error": "Remote engine: $message"},
          }),
        );
        if (!_engineStarted) {
          // The start request itself failed; let the UI fall back to stopped.
          _addRaw(jsonEncode({"EngineStopped": {}}));
        }
      case "replaced":
        _log("warn", "Another Intiface Central took over the remote engine. It is still running on the Pi.");
      case "pong":
        break;
      default:
        logWarning("Unknown remote engine frame: $frame");
    }
  }

  void _onDisconnected() {
    var wasRunning = _engineStarted;
    _session = null;
    _subscription = null;
    _stopped?.complete();
    _stopped = null;
    if (wasRunning) {
      _engineStarted = false;
      if (!_closingDeliberately) {
        _log("warn", "Lost connection to the remote engine. It keeps running on the Pi; press Start to reconnect.");
      }
      // Reset the UI; the engine itself is not stopped.
      _addRaw(jsonEncode({"EngineStopped": {}}));
    }
  }

  void _addRaw(String message) {
    if (!_rawStream.isClosed) {
      _rawStream.add(message);
    }
  }

  void _log(String level, String message) {
    switch (level) {
      case "warn":
        logWarning(message);
      case "error":
        logError(message);
      default:
        logInfo(message);
    }
    _addRaw(
      jsonEncode({
        "EngineProviderLog": {
          "timestamp": DateTime.now().toIso8601String(),
          "level": level.toUpperCase(),
          "message": message,
        },
      }),
    );
  }

  void _sendFrame(Map<String, dynamic> frame) {
    var session = _session;
    if (session == null) {
      logWarning("Remote engine not connected, dropping ${frame["type"]} message");
      return;
    }
    session.socket.add(jsonEncode(frame));
  }

  @override
  Future<void> stop() async {
    if (_session == null) {
      return;
    }
    if (_engineStarted) {
      _stopped = Completer();
      _sendFrame({"type": "stop"});
      try {
        await _stopped!.future.timeout(_stopTimeout);
      } on TimeoutException {
        logError("Remote engine did not confirm stop within ${_stopTimeout.inSeconds}s");
      }
    }
    await _closeSession();
  }

  /// Disconnect without stopping the engine on the Pi.
  Future<void> detach() => _closeSession();

  Future<void> _closeSession() async {
    var session = _session;
    if (session == null) {
      return;
    }
    _closingDeliberately = true;
    // Cancel first so onDone doesn't also fire; then settle state once here.
    await _subscription?.cancel();
    await session.socket.close();
    _onDisconnected();
  }

  @override
  Future<bool> runtimeStarted() async => _session != null;

  @override
  void send(String msg) => _sendFrame({"type": "engine", "message": msg});

  @override
  void sendBackdoorMessage(String msg) => _sendFrame({"type": "backdoor", "message": msg});

  /// Push a locally edited user device config to the Pi. Applied live there.
  void pushUserConfig(String json) => _sendFrame({"type": "set_user_config", "json": json});

  @override
  Stream<String> get engineRawMessageStream => _rawStream.stream;
}
