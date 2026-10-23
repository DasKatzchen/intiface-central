import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:intiface_central/bloc/engine/engine_provider.dart';
import 'package:intiface_central/bloc/engine/remote_engine_provider.dart';
import 'package:intiface_central/src/rust/api/runtime.dart';

EngineOptionsExternal _options({String? userConfig}) => EngineOptionsExternal(
  serverName: "Remote Test",
  userDeviceConfigJson: userConfig,
  websocketListenAddress: "127.0.0.1:12397",
  frontendInProcessChannel: false,
  maxPingTime: 0,
  useBluetoothLe: false,
  useSerialPort: true,
  useLovenseDongleSerial: false,
  useLovenseDongleHid: false,
  useSdlGamepad: false,
  useLovenseConnect: false,
  useDeviceWebsocketServer: false,
  useSimulatedDevices: true,
  crashMainThread: false,
  crashTaskThread: false,
  broadcastServerMdns: false,
  repeaterMode: false,
  emitOutputObservations: false,
);

/// Minimal stand-in for intiface-remote-daemon, for protocol edge cases.
class FakeDaemon {
  late HttpServer server;
  final frames = <Map<String, dynamic>>[];
  WebSocket? socket;
  bool running;
  String? rejectWith;

  FakeDaemon({this.running = false, this.rejectWith});

  int get port => server.port;

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      var ws = await WebSocketTransformer.upgrade(req);
      socket = ws;
      ws.listen((data) {
        var frame = jsonDecode(data as String) as Map<String, dynamic>;
        frames.add(frame);
        if (frame["type"] == "hello") {
          if (rejectWith != null) {
            ws.add(jsonEncode({"type": "error", "message": rejectWith}));
            ws.close();
            return;
          }
          ws.add(jsonEncode({"type": "welcome", "protocol": 1, "daemon_version": "t", "engine_version": "t", "hostname": "fakepi", "running": running}));
          if (running) {
            // Replay arrives immediately after the welcome.
            ws.add(jsonEncode({"type": "raw", "message": '{"EngineStarted":{}}'}));
          }
        }
        if (frame["type"] == "start") {
          ws.add(jsonEncode({"type": "raw", "message": '{"EngineStarted":{}}'}));
        }
      });
    });
  }

  Future<void> close() => server.close(force: true);
}

Future<List<String>> _collect(Stream<String> s, int count) => s.take(count).toList().timeout(const Duration(seconds: 15));

bool _isProviderLog(String m) => m.startsWith('{"EngineProviderLog"');

void main() {
  group('address normalization', () {
    test('adds scheme and default port', () {
      expect(normalizeRemoteEngineAddress("192.168.1.50").toString(), "ws://192.168.1.50:12346");
      expect(normalizeRemoteEngineAddress(" pi.local:9000 ").toString(), "ws://pi.local:9000");
      expect(normalizeRemoteEngineAddress("wss://pi.example").port, 12346);
    });
    test('rejects empty and non-websocket addresses', () {
      expect(() => normalizeRemoteEngineAddress(""), throwsFormatException);
      expect(() => normalizeRemoteEngineAddress("http://pi"), throwsFormatException);
    });
  });

  test('options serialize with snake_case daemon field names', () {
    var json = engineOptionsToRemoteJson(_options(userConfig: "{}"));
    expect(json["server_name"], "Remote Test");
    expect(json["use_serial_port"], true);
    expect(json["user_device_config_json"], "{}");
    expect(json.containsKey("user_device_config_path"), isFalse);
  });

  group('against a fake daemon', () {
    late FakeDaemon daemon;
    tearDown(() => daemon.close());

    RemoteEngineProvider provider() => RemoteEngineProvider(
      connectionInfo: () => RemoteEngineConnectionInfo(address: "127.0.0.1:${daemon.port}", token: "secret-token-123456"),
    );

    test('bad token surfaces a readable start error', () async {
      daemon = FakeDaemon(rejectWith: "Invalid access token");
      await daemon.start();
      await expectLater(
        provider().start(options: _options()),
        throwsA(isA<EngineProviderStartException>().having((e) => e.message, 'message', contains("Invalid access token"))),
      );
    });

    test('sends start when engine is not running', () async {
      daemon = FakeDaemon();
      await daemon.start();
      var p = provider();
      await p.start(options: _options());
      var msgs = (await _collect(p.engineRawMessageStream, 3)).where((m) => !_isProviderLog(m)).toList();
      expect(msgs, ['{"EngineStarted":{}}']);
      expect(daemon.frames.map((f) => f["type"]), ["hello", "start"]);
      expect(daemon.frames[0]["token"], "secret-token-123456");
    });

    test('attaches without sending start, and keeps replayed frames', () async {
      daemon = FakeDaemon(running: true);
      await daemon.start();
      var p = provider();
      await p.start(options: _options());
      var msgs = await _collect(p.engineRawMessageStream, 3);
      expect(msgs.where((m) => !_isProviderLog(m)), ['{"EngineStarted":{}}']);
      expect(daemon.frames.map((f) => f["type"]), ["hello"]);
    });

    test('losing the connection resets the UI with EngineStopped', () async {
      daemon = FakeDaemon(running: true);
      await daemon.start();
      var p = provider();
      await p.start(options: _options());
      var all = <String>[];
      var sub = p.engineRawMessageStream.listen(all.add);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await daemon.socket!.close();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await sub.cancel();
      expect(all.last, '{"EngineStopped":{}}');
      expect(p.isConnected, isFalse);
    });
  });

  // Runs Central's provider against the real daemon binary when available:
  //   cargo build --manifest-path remote/intiface-remote-daemon/Cargo.toml
  //   INTIFACE_REMOTE_DAEMON=remote/intiface-remote-daemon/target/debug/intiface-remote-daemon flutter test ...
  var daemonBinary = Platform.environment["INTIFACE_REMOTE_DAEMON"];
  test('end to end against intiface-remote-daemon', () async {
    const token = "central-e2e-token-0123456789";
    const port = 12396;
    var state = await Directory.systemTemp.createTemp("intiface-remote");
    var proc = await Process.start(
      daemonBinary!,
      ["--listen", "127.0.0.1:$port", "--state-dir", state.path, "--keep-listen-address"],
      environment: {"INTIFACE_REMOTE_TOKEN": token, "RUST_LOG": "warn"},
    );
    proc.stderr.transform(utf8.decoder).listen(stderr.write);
    try {
      var info = const RemoteEngineConnectionInfo(address: "127.0.0.1:$port", token: token);
      RemoteEngineWelcome? welcome;
      for (var i = 0; i < 50 && welcome == null; i++) {
        try {
          welcome = await RemoteEngineProvider.testConnection(info);
        } catch (_) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
      expect(welcome!.running, isFalse);

      var userConfig = jsonEncode({
        "version": {"major": 5, "minor": 0},
        "user_configs": {
          "simulated_devices": [
            {"identifier": "simulated-1vibe", "address": "simulated:central-e2e"},
          ],
        },
      });
      var p = RemoteEngineProvider(connectionInfo: () => info);
      var configs = <String>[];
      p.userConfigStream.listen(configs.add);
      await p.start(options: _options(userConfig: userConfig));
      var raw = p.engineRawMessageStream.asBroadcastStream();
      Future<String> next(String needle) => raw.firstWhere((m) => m.contains(needle)).timeout(const Duration(seconds: 15));

      await next("EngineServerCreated");
      p.sendBackdoorMessage(
        jsonEncode([
          {"RequestServerInfo": {"Id": 1, "ClientName": "central", "ProtocolVersionMajor": 4, "ProtocolVersionMinor": 0}},
        ]),
      );
      await next("ServerInfo");
      p.sendBackdoorMessage(jsonEncode([{"StartScanning": {"Id": 2}}]));
      var dev = await next("DeviceConnected");
      var index = jsonDecode(dev)["DeviceConnected"]["index"];
      p.sendBackdoorMessage(
        jsonEncode([
          {"OutputCmd": {"Id": 3, "DeviceIndex": index, "FeatureIndex": 0, "Command": {"Vibrate": {"Value": 30}}}},
        ]),
      );
      expect(await next('"Id":3'), contains('"Ok"'));
      expect(configs.any((c) => c.contains("central-e2e")), isTrue, reason: "Pi pushes its user config");

      // Detach leaves the engine running; a new provider reattaches.
      await p.detach();
      var p2 = RemoteEngineProvider(connectionInfo: () => info);
      await p2.start(options: _options());
      var raw2 = p2.engineRawMessageStream.asBroadcastStream();
      expect(await raw2.firstWhere((m) => m.contains("DeviceConnected")).timeout(const Duration(seconds: 10)), contains("Simulated"));

      var stoppedSeen = raw2.firstWhere((m) => m.contains("EngineStopped")).timeout(const Duration(seconds: 20));
      await p2.stop();
      await stoppedSeen;
      expect(p2.isConnected, isFalse);
    } finally {
      proc.kill();
      await proc.exitCode;
      await state.delete(recursive: true);
    }
  }, skip: daemonBinary == null ? "set INTIFACE_REMOTE_DAEMON to the daemon binary to run" : false, timeout: const Timeout(Duration(minutes: 2)));
}
