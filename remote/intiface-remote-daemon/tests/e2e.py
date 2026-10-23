"""End-to-end test for intiface-remote-daemon.

Starts the daemon binary, then acts as Intiface Central: authenticates,
starts the engine with a simulated device, drives it over the backdoor
channel, reconnects to check state replay, edits the device config live,
and stops the engine.

Usage: python tests/e2e.py path/to/intiface-remote-daemon
"""

import asyncio
import json
import os
import subprocess
import sys
import tempfile

import websockets

TOKEN = "e2e-test-token-0123456789"
PORT = 12399
URL = f"ws://127.0.0.1:{PORT}"
USER_CONFIG = json.dumps(
    {
        "version": {"major": 5, "minor": 0},
        "user_configs": {
            "simulated_devices": [
                {"identifier": "simulated-1vibe", "address": "simulated:e2e-vibe"}
            ]
        },
    }
)
OPTIONS = {
    "server_name": "Pi E2E",
    "websocket_listen_address": "127.0.0.1:12398",
    "max_ping_time": 0,
    "use_simulated_devices": True,
    "user_device_config_json": USER_CONFIG,
}


async def recv(ws, pred, what, timeout=15):
    async def loop():
        while True:
            m = json.loads(await ws.recv())
            if pred(m):
                return m

    try:
        return await asyncio.wait_for(loop(), timeout)
    except asyncio.TimeoutError:
        raise AssertionError(f"timed out waiting for {what}")


def raw_has(key):
    return lambda m: m["type"] == "raw" and key in m["message"]


async def hello(ws, token=TOKEN):
    await ws.send(json.dumps({"type": "hello", "token": token, "protocol": 1, "client_name": "e2e"}))
    return json.loads(await ws.recv())


async def main(binary):
    state = tempfile.mkdtemp()
    env = dict(os.environ, INTIFACE_REMOTE_TOKEN=TOKEN, RUST_LOG="warn")
    proc = subprocess.Popen(
        [binary, "--listen", f"127.0.0.1:{PORT}", "--state-dir", state, "--keep-listen-address"],
        env=env,
    )
    try:
        for _ in range(50):
            try:
                async with websockets.connect(URL):
                    break
            except OSError:
                await asyncio.sleep(0.1)

        # 1. A bad token is rejected.
        async with websockets.connect(URL) as ws:
            m = await hello(ws, token="wrong-token-wrong-token")
            assert m["type"] == "error" and "token" in m["message"], m
        print("ok  bad token rejected")

        async with websockets.connect(URL) as ws:
            m = await hello(ws)
            assert m["type"] == "welcome" and m["running"] is False, m
            print("ok  welcome", m["hostname"], m["daemon_version"])

            # 2. Start with a simulated device; it should connect.
            await ws.send(json.dumps({"type": "start", "options": OPTIONS}))
            await recv(ws, raw_has("EngineStarted"), "EngineStarted")
            await recv(ws, raw_has("EngineServerCreated"), "EngineServerCreated")
            print("ok  engine started")

            # 3. Engine frontend channel: version request.
            await ws.send(json.dumps({"type": "engine", "message": json.dumps({"RequestEngineVersion": {"expected_version": 1}})}))
            await recv(ws, raw_has("EngineVersion"), "EngineVersion")
            print("ok  engine version via frontend channel")

            # 4. Backdoor: handshake, list devices, vibrate.
            def bd(msg):
                return ws.send(json.dumps({"type": "backdoor", "message": json.dumps([msg])}))

            await bd({"RequestServerInfo": {"Id": 1, "ClientName": "bd", "ProtocolVersionMajor": 4, "ProtocolVersionMinor": 0}})
            await recv(ws, raw_has("ServerInfo"), "ServerInfo")
            await bd({"StartScanning": {"Id": 4}})
            dev = await recv(ws, raw_has("DeviceConnected"), "DeviceConnected")
            index = json.loads(dev["message"])["DeviceConnected"]["index"]
            print("ok  scan found simulated device, index", index)
            await bd({"RequestDeviceList": {"Id": 2}})
            dl = await recv(ws, raw_has("DeviceList"), "DeviceList")
            assert "Simulated" in dl["message"], dl
            await bd({"OutputCmd": {"Id": 3, "DeviceIndex": index, "FeatureIndex": 0, "Command": {"Vibrate": {"Value": 50}}}})
            ok = await recv(ws, lambda m: m["type"] == "raw" and '"Id":3' in m["message"], "OutputCmd reply")
            assert '"Ok"' in ok["message"], ok
            print("ok  backdoor device control")

        # 5. Reconnect while running: state is replayed.
        async with websockets.connect(URL) as ws:
            m = await hello(ws)
            assert m["running"] is True, m
            await recv(ws, raw_has("EngineStarted"), "replayed EngineStarted")
            await recv(ws, raw_has("DeviceConnected"), "replayed DeviceConnected")
            print("ok  reconnect replays running state")

            # 6. Live config edit: rename the device, read it back.
            await ws.send(json.dumps({"type": "get_user_config"}))
            cfg = await recv(ws, lambda m: m["type"] == "user_config", "user_config")
            parsed = json.loads(cfg["json"])
            devices = parsed["user_configs"].get("devices", [])
            assert devices, parsed
            devices[0]["config"]["user_config"]["display_name"] = "Renamed On Pi"
            await ws.send(json.dumps({"type": "set_user_config", "json": json.dumps(parsed)}))
            await ws.send(json.dumps({"type": "get_user_config"}))
            cfg = await recv(ws, lambda m: m["type"] == "user_config", "user_config after edit")
            assert "Renamed On Pi" in cfg["json"], cfg
            print("ok  live user config update")

            # 7. A second controller replaces the first.
            async with websockets.connect(URL) as ws2:
                await hello(ws2)
                await recv(ws, lambda m: m["type"] == "replaced", "replaced notice")
                print("ok  newer controller takes over")

                # 8. Stop.
                await ws2.send(json.dumps({"type": "stop"}))
                await recv(ws2, raw_has("EngineStopped"), "EngineStopped")
                await recv(ws2, lambda m: m["type"] == "status" and m["running"] is False, "stopped status")
                print("ok  engine stopped")

        saved = open(os.path.join(state, "buttplug-user-device-config-v5.json")).read()
        assert "Renamed On Pi" in saved
        assert os.path.exists(os.path.join(state, "last-engine-options.json"))
        print("ok  config and options persisted on disk")
        print("ALL PASSED")
    finally:
        proc.terminate()
        proc.wait(10)


if __name__ == "__main__":
    asyncio.run(main(sys.argv[1]))
