import 'package:flutter/material.dart';
import 'package:flutter_settings_ui/flutter_settings_ui.dart';
import 'package:intiface_central/bloc/configuration/intiface_configuration_cubit.dart';
import 'package:intiface_central/bloc/engine/remote_engine_provider.dart';

/// Settings for driving a headless engine (intiface-remote-daemon) on another
/// machine, such as a Raspberry Pi, instead of the built-in engine.
class SettingsRemoteEngineWidget extends AbstractSettingsSection {
  final IntifaceConfigurationCubit cubit;
  final bool engineIsRunning;

  const SettingsRemoteEngineWidget({super.key, required this.cubit, required this.engineIsRunning});

  Future<void> _editText(
    BuildContext context, {
    required String title,
    required String initial,
    required String hint,
    required void Function(String) onSave,
    bool obscure = false,
  }) {
    var controller = TextEditingController(text: initial);
    return showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          obscureText: obscure,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(hintText: hint),
          onSubmitted: (value) {
            onSave(value.trim());
            Navigator.pop(context);
          },
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          TextButton(
            onPressed: () {
              onSave(controller.text.trim());
              Navigator.pop(context);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<void> _testConnection(BuildContext context) async {
    String title;
    String body;
    try {
      var welcome = await RemoteEngineProvider.testConnection(
        RemoteEngineConnectionInfo(address: cubit.remoteEngineAddress, token: cubit.remoteEngineToken),
      );
      title = 'Connected to ${welcome.hostname}';
      body =
          'intiface-remote ${welcome.daemonVersion}, engine ${welcome.engineVersion}.\n'
          'Engine is ${welcome.running ? "running" : "not running"} on the remote host.';
    } catch (e) {
      title = 'Connection failed';
      body = e.toString().replaceFirst('Exception while starting Intiface Engine: ', '');
    }
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Ok'))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    var address = cubit.remoteEngineAddress;
    var hasToken = cubit.remoteEngineToken.isNotEmpty;
    return SettingsSection(
      title: const Text("Remote Engine (Raspberry Pi)", style: TextStyle(fontFamily: 'Roboto')),
      tiles: [
        SettingsTile.switchTile(
          enabled: !engineIsRunning,
          initialValue: cubit.useRemoteEngine,
          onToggle: (value) => cubit.useRemoteEngine = value,
          title: const Text("Use Remote Engine"),
          description: const Text(
            "Run the engine on another machine running intiface-remote. Devices connect to that machine, "
            "and game clients connect to its address.",
          ),
        ),
        SettingsTile.navigation(
          enabled: !engineIsRunning,
          title: const Text("Remote Address"),
          value: Text(address.isEmpty ? "Not set" : address),
          onPressed: (context) => _editText(
            context,
            title: 'Remote Engine Address',
            initial: address,
            hint: 'ws://192.168.1.50:12346',
            onSave: (v) => cubit.remoteEngineAddress = v,
          ),
        ),
        SettingsTile.navigation(
          enabled: !engineIsRunning,
          title: const Text("Access Token"),
          value: Text(hasToken ? "Set" : "Not set"),
          onPressed: (context) => _editText(
            context,
            title: 'Access Token',
            initial: cubit.remoteEngineToken,
            hint: 'From /etc/intiface-remote/token on the Pi',
            obscure: true,
            onSave: (v) => cubit.remoteEngineToken = v,
          ),
        ),
        SettingsTile.navigation(
          enabled: address.isNotEmpty && hasToken,
          title: const Text("Test Connection"),
          onPressed: _testConnection,
        ),
      ],
    );
  }
}
