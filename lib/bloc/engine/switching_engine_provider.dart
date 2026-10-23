// Chooses between the local (in-process) engine and a remote engine each time
// the engine starts, so switching modes in settings needs no app restart.

import 'package:intiface_central/bloc/engine/engine_provider.dart';
import 'package:intiface_central/bloc/engine/remote_engine_provider.dart';
import 'package:intiface_central/src/rust/api/runtime.dart';

class SwitchingEngineProvider implements EngineProvider {
  SwitchingEngineProvider({required this.local, required this.remote, required bool Function() useRemote})
    : _useRemote = useRemote,
      _active = local;

  final EngineProvider local;
  final RemoteEngineProvider remote;
  final bool Function() _useRemote;
  EngineProvider _active;

  bool get remoteActive => identical(_active, remote);

  @override
  Future<void> start({required EngineOptionsExternal options}) {
    _active = _useRemote() ? remote : local;
    return _active.start(options: options);
  }

  @override
  Future<void> stop() => _active.stop();

  @override
  Future<bool> runtimeStarted() => _active.runtimeStarted();

  @override
  void send(String msg) => _active.send(msg);

  @override
  void sendBackdoorMessage(String msg) => _active.sendBackdoorMessage(msg);

  @override
  Stream<String> get engineRawMessageStream => _active.engineRawMessageStream;
}
