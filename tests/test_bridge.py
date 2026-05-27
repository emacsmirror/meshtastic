"""Tests for meshtastic-bridge.py.

Strategy: mock meshtastic and pubsub before importing the bridge module so the
test suite runs without a real serial device or installed meshtastic library.
Individual functions are tested in isolation; the main() loop is tested by
patching sys.stdin and capturing stdout.
"""

import importlib.util
import io
import json
import sys
from pathlib import Path
from unittest.mock import MagicMock, PropertyMock, call, patch

import pytest

# ---------------------------------------------------------------------------
# Mock meshtastic and pubsub before importing the bridge.
# These must be in sys.modules before the import below.
# ---------------------------------------------------------------------------

_mock_pub = MagicMock()
_mock_pub.AUTO_TOPIC = object()  # unique sentinel used as default parameter

_mock_pubsub_module = MagicMock()
_mock_pubsub_module.pub = _mock_pub

_mock_meshtastic = MagicMock()
_mock_serial_iface_module = MagicMock()
_mock_meshtastic.serial_interface = _mock_serial_iface_module

sys.modules.setdefault("meshtastic", _mock_meshtastic)
sys.modules.setdefault("meshtastic.serial_interface", _mock_serial_iface_module)
sys.modules.setdefault("pubsub", _mock_pubsub_module)

# Load the bridge module from its file path (hyphen in filename prevents normal import).
_bridge_path = Path(__file__).parent.parent / "meshtastic-bridge.py"
_spec = importlib.util.spec_from_file_location("meshtastic_bridge", _bridge_path)
bridge = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(bridge)


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture(autouse=True)
def reset_globals():
    """Reset module-level state between tests."""
    bridge._iface = None
    bridge._pending_traceroutes.clear()
    _mock_serial_iface_module.SerialInterface.reset_mock()
    _mock_pub.reset_mock()
    yield
    bridge._iface = None
    bridge._pending_traceroutes.clear()


def _parse_stdout(capsys) -> list[dict]:
    """Return all JSON objects emitted to stdout during the test."""
    raw = capsys.readouterr().out
    result = []
    for line in raw.splitlines():
        line = line.strip()
        if line:
            result.append(json.loads(line))
    return result


def _default_iface(**overrides):
    """Build a minimal mock SerialInterface."""
    iface = MagicMock()
    iface.getMyNodeInfo.return_value = {
        "user": {"id": "!deadbeef", "longName": "TestNode", "shortName": "TN"}
    }
    iface.nodes = {}
    iface.localNode.channels = []
    for k, v in overrides.items():
        setattr(iface, k, v)
    return iface


def _run_main(commands: list[str], iface=None, port: str = "/dev/ttyUSB0") -> list[dict]:
    """Run bridge.main() with the given stdin commands and return emitted JSON."""
    if iface is None:
        iface = _default_iface()
    _mock_serial_iface_module.SerialInterface.return_value = iface

    stdin_text = "\n".join(commands) + "\n"

    captured = io.StringIO()
    with (
        patch("sys.argv", ["bridge", port]),
        patch("sys.stdin", io.StringIO(stdin_text)),
        patch("sys.stdout", captured),
    ):
        bridge.main()

    captured.seek(0)
    result = []
    for line in captured.read().splitlines():
        line = line.strip()
        if line:
            try:
                result.append(json.loads(line))
            except json.JSONDecodeError:
                result.append({"_raw": line})
    return result


# ===========================================================================
# _node_id_from_num
# ===========================================================================


class TestNodeIdFromNum:
    def test_typical_value(self):
        assert bridge._node_id_from_num(0x3B32C054) == "!3b32c054"

    def test_broadcast_address(self):
        assert bridge._node_id_from_num(0xFFFFFFFF) == "!ffffffff"

    def test_small_value_is_zero_padded(self):
        assert bridge._node_id_from_num(1) == "!00000001"

    def test_zero_returns_empty(self):
        assert bridge._node_id_from_num(0) == ""

    def test_none_returns_empty(self):
        assert bridge._node_id_from_num(None) == ""


# ===========================================================================
# _emit
# ===========================================================================


class TestEmit:
    def test_writes_json_line_to_stdout(self, capsys):
        bridge._emit({"type": "test", "value": 42})
        msgs = _parse_stdout(capsys)
        assert msgs == [{"type": "test", "value": 42}]

    def test_output_ends_with_newline(self, capsys):
        bridge._emit({"x": 1})
        assert capsys.readouterr().out.endswith("\n")

    def test_unicode_is_preserved(self, capsys):
        bridge._emit({"text": "hola 🌍"})
        msgs = _parse_stdout(capsys)
        assert msgs[0]["text"] == "hola 🌍"


# ===========================================================================
# _on_receive
# ===========================================================================


def _text_packet(**overrides):
    pkt = {
        "decoded": {"portnum": "TEXT_MESSAGE_APP", "text": "hello"},
        "from": 0x3B32C054,
        "to": 0xFFFFFFFF,
        "fromId": "!3b32c054",
        "toId": "!ffffffff",
        "id": 12345,
        "channel": 0,
        "rxTime": 1_700_000_000,
        "rxSnr": 7.5,
        "rxRssi": -85,
        "hopLimit": 3,
        "hopStart": 3,
    }
    pkt.update(overrides)
    return pkt


class TestOnReceive:
    def test_text_message_emits_message_event(self, capsys):
        bridge._on_receive(_text_packet(), MagicMock())
        msgs = _parse_stdout(capsys)
        assert len(msgs) == 1
        m = msgs[0]
        assert m["type"] == "message"
        assert m["text"] == "hello"
        assert m["from"] == "!3b32c054"
        assert m["to"] == "!ffffffff"
        assert m["id"] == 12345
        assert m["channel"] == 0

    def test_non_text_portnum_produces_no_output(self, capsys):
        pkt = _text_packet(decoded={"portnum": "NODEINFO_APP"})
        bridge._on_receive(pkt, MagicMock())
        assert capsys.readouterr().out == ""

    def test_prefers_fromId_over_from_num(self, capsys):
        pkt = _text_packet(fromId="!aabbccdd")
        bridge._on_receive(pkt, MagicMock())
        msgs = _parse_stdout(capsys)
        assert msgs[0]["from"] == "!aabbccdd"

    def test_falls_back_to_from_num_when_no_fromId(self, capsys):
        pkt = _text_packet()
        del pkt["fromId"]
        bridge._on_receive(pkt, MagicMock())
        msgs = _parse_stdout(capsys)
        assert msgs[0]["from"] == "!3b32c054"

    def test_missing_rxTime_uses_current_time(self, capsys):
        pkt = _text_packet(rxTime=None)
        bridge._on_receive(pkt, MagicMock())
        msgs = _parse_stdout(capsys)
        assert isinstance(msgs[0]["rxTime"], int)
        assert msgs[0]["rxTime"] > 0

    def test_broken_packet_emits_error_not_crash(self, capsys):
        bridge._on_receive(None, MagicMock())
        msgs = _parse_stdout(capsys)
        assert msgs[0]["type"] == "error"

    def test_missing_text_field_defaults_to_empty(self, capsys):
        pkt = _text_packet(decoded={"portnum": "TEXT_MESSAGE_APP"})
        bridge._on_receive(pkt, MagicMock())
        msgs = _parse_stdout(capsys)
        assert msgs[0]["text"] == ""


# ===========================================================================
# _on_connection
# ===========================================================================


class TestOnConnection:
    def _iface_with_node(self, node_id="!aabbccdd", long_name="Alpha", short_name="AL"):
        iface = MagicMock()
        iface.getMyNodeInfo.return_value = {
            "user": {"id": node_id, "longName": long_name, "shortName": short_name}
        }
        return iface

    def test_emits_connected_event(self, capsys):
        bridge._on_connection(self._iface_with_node())
        msgs = _parse_stdout(capsys)
        assert msgs[0]["type"] == "connected"
        assert msgs[0]["nodeId"] == "!aabbccdd"
        assert msgs[0]["longName"] == "Alpha"

    def test_fallback_when_getMyNodeInfo_raises(self, capsys):
        iface = MagicMock()
        iface.getMyNodeInfo.side_effect = Exception("timeout")
        iface.myInfo.my_node_num = 0xAABBCCDD  # protobuf snake_case
        iface.nodes = {
            "!aabbccdd": {"user": {"longName": "Fallback", "shortName": "FB"}}
        }
        bridge._on_connection(iface)
        msgs = _parse_stdout(capsys)
        assert msgs[0]["type"] == "connected"
        assert msgs[0]["nodeId"] == "!aabbccdd"
        assert msgs[0]["longName"] == "Fallback"

    def test_emits_empty_strings_on_total_failure(self, capsys):
        iface = MagicMock()
        iface.getMyNodeInfo.side_effect = Exception("fail1")
        type(iface).myInfo = PropertyMock(side_effect=Exception("fail2"))
        bridge._on_connection(iface)
        msgs = _parse_stdout(capsys)
        assert msgs[0]["type"] == "connected"
        assert msgs[0]["nodeId"] == ""
        assert msgs[0]["longName"] == ""


# ===========================================================================
# _on_disconnect
# ===========================================================================


class TestOnDisconnect:
    def test_emits_error_and_exits_with_zero(self, capsys, monkeypatch):
        exited = {}
        monkeypatch.setattr(bridge.os, "_exit", lambda code: exited.update({"code": code}))
        bridge._on_disconnect(MagicMock())
        assert exited == {"code": 0}
        msgs = _parse_stdout(capsys)
        assert msgs[0]["type"] == "error"
        assert "disconnect" in msgs[0]["message"].lower()

    def test_close_exception_does_not_propagate(self, capsys, monkeypatch):
        monkeypatch.setattr(bridge.os, "_exit", lambda code: None)
        iface = MagicMock()
        iface.close.side_effect = Exception("port gone")
        bridge._on_disconnect(iface)  # must not raise

    def test_calls_close_on_interface(self, capsys, monkeypatch):
        monkeypatch.setattr(bridge.os, "_exit", lambda code: None)
        iface = MagicMock()
        bridge._on_disconnect(iface)
        iface.close.assert_called_once()


# ===========================================================================
# _send_nodes
# ===========================================================================


class TestSendNodes:
    def test_emits_nodes_list(self, capsys):
        iface = _default_iface(
            nodes={
                "!00000001": {
                    "num": 1,
                    "user": {"id": "!00000001", "longName": "Node1", "shortName": "N1"},
                    "hopsAway": 2,
                    "lastHeard": 1_700_000_000,
                    "snr": 8.0,
                }
            }
        )
        bridge._iface = iface
        bridge._send_nodes()
        msgs = _parse_stdout(capsys)
        assert msgs[0]["type"] == "nodes"
        nodes = msgs[0]["data"]
        assert len(nodes) == 1
        assert nodes[0]["nodeId"] == "!00000001"
        assert nodes[0]["longName"] == "Node1"
        assert nodes[0]["hopsAway"] == 2

    def test_no_output_when_iface_is_none(self, capsys):
        bridge._iface = None
        bridge._send_nodes()
        assert capsys.readouterr().out == ""

    def test_emits_error_on_exception(self, capsys):
        iface = MagicMock()
        type(iface).nodes = PropertyMock(side_effect=Exception("serial error"))
        bridge._iface = iface
        bridge._send_nodes()
        msgs = _parse_stdout(capsys)
        assert msgs[0]["type"] == "error"

    def test_multiple_nodes(self, capsys):
        iface = _default_iface(
            nodes={
                f"!0000000{i}": {
                    "num": i,
                    "user": {"id": f"!0000000{i}", "longName": f"Node{i}", "shortName": f"N{i}"},
                    "hopsAway": i,
                    "lastHeard": 0,
                    "snr": None,
                }
                for i in range(1, 4)
            }
        )
        bridge._iface = iface
        bridge._send_nodes()
        msgs = _parse_stdout(capsys)
        assert len(msgs[0]["data"]) == 3

    def test_node_id_falls_back_to_key_string(self, capsys):
        iface = _default_iface(
            nodes={
                "!cafebabe": {
                    "num": 0xCAFEBABE,
                    "user": {"longName": "NoId", "shortName": "NI"},
                    "hopsAway": 0,
                    "lastHeard": 0,
                    "snr": None,
                }
            }
        )
        bridge._iface = iface
        bridge._send_nodes()
        msgs = _parse_stdout(capsys)
        assert msgs[0]["data"][0]["nodeId"] == "!cafebabe"


# ===========================================================================
# _send_channels
# ===========================================================================


def _make_channel(index: int, name: str, role: int):
    ch = MagicMock()
    ch.index = index
    ch.role = role
    ch.settings = MagicMock()
    ch.settings.name = name
    return ch


class TestSendChannels:
    def test_emits_channel_list(self, capsys):
        iface = _default_iface()
        iface.localNode.channels = [
            _make_channel(0, "MediumFast", 1),
            _make_channel(1, "LongFast", 2),
        ]
        bridge._iface = iface
        bridge._send_channels()
        msgs = _parse_stdout(capsys)
        assert msgs[0]["type"] == "channels"
        data = msgs[0]["data"]
        assert data[0]["name"] == "MediumFast"
        assert data[0]["role"] == 1
        assert data[1]["name"] == "LongFast"

    def test_no_output_when_iface_is_none(self, capsys):
        bridge._iface = None
        bridge._send_channels()
        assert capsys.readouterr().out == ""

    def test_channel_with_no_settings_uses_empty_name(self, capsys):
        iface = _default_iface()
        ch = MagicMock()
        ch.index = 0
        ch.role = 1
        ch.settings = None
        iface.localNode.channels = [ch]
        bridge._iface = iface
        bridge._send_channels()
        msgs = _parse_stdout(capsys)
        assert msgs[0]["data"][0]["name"] == ""

    def test_emits_error_on_exception(self, capsys):
        iface = _default_iface()
        type(iface.localNode).channels = PropertyMock(side_effect=Exception("fail"))
        bridge._iface = iface
        bridge._send_channels()
        msgs = _parse_stdout(capsys)
        assert msgs[0]["type"] == "error"


# ===========================================================================
# _send_info
# ===========================================================================


class TestSendInfo:
    def test_emits_info_event(self, capsys):
        iface = _default_iface()
        bridge._iface = iface
        bridge._send_info()
        msgs = _parse_stdout(capsys)
        assert msgs[0]["type"] == "info"
        assert msgs[0]["nodeId"] == "!deadbeef"
        assert msgs[0]["longName"] == "TestNode"

    def test_no_output_when_iface_is_none(self, capsys):
        bridge._iface = None
        bridge._send_info()
        assert capsys.readouterr().out == ""

    def test_emits_error_on_exception(self, capsys):
        iface = MagicMock()
        iface.getMyNodeInfo.side_effect = Exception("fail")
        bridge._iface = iface
        bridge._send_info()
        msgs = _parse_stdout(capsys)
        assert msgs[0]["type"] == "error"


# ===========================================================================
# main() – stdin command loop
# ===========================================================================


class TestMainLoop:
    def test_quit_terminates_loop_cleanly(self):
        msgs = _run_main(['{"action": "quit"}'])
        errors = [m for m in msgs if m.get("type") == "error"]
        assert errors == []

    def test_serial_connect_failure_emits_error_and_exits(self):
        _mock_serial_iface_module.SerialInterface.side_effect = Exception("no such port")
        with pytest.raises(SystemExit) as exc_info:
            _run_main([])
        assert exc_info.value.code == 1
        _mock_serial_iface_module.SerialInterface.side_effect = None

    def test_channel_send_does_not_pass_destinationId_none(self):
        """Regression: passing destinationId=None crashes the meshtastic library."""
        iface = _default_iface()
        _run_main(
            ['{"action": "send", "text": "hello", "channel": 0, "id": "cmd-1"}',
             '{"action": "quit"}'],
            iface=iface,
        )
        call_kwargs = iface.sendText.call_args
        assert call_kwargs is not None
        assert "destinationId" not in call_kwargs.kwargs, (
            "destinationId must not be passed for channel messages "
            "(None would crash the meshtastic library)"
        )

    def test_channel_send_emits_sent_confirmation(self):
        iface = _default_iface()
        msgs = _run_main(
            ['{"action": "send", "text": "hi", "channel": 0, "id": "cmd-1"}',
             '{"action": "quit"}'],
            iface=iface,
        )
        sent = [m for m in msgs if m.get("type") == "sent"]
        assert len(sent) == 1
        assert sent[0]["id"] == "cmd-1"

    def test_channel_send_uses_correct_channelIndex(self):
        iface = _default_iface()
        _run_main(
            ['{"action": "send", "text": "hi", "channel": 2, "id": "cmd-1"}',
             '{"action": "quit"}'],
            iface=iface,
        )
        iface.sendText.assert_called_once_with("hi", channelIndex=2, wantAck=False)

    def test_dm_send_passes_destinationId_and_wantAck(self):
        iface = _default_iface()
        _run_main(
            ['{"action": "send", "text": "hi", "dest": "!aabbccdd", "id": "cmd-2"}',
             '{"action": "quit"}'],
            iface=iface,
        )
        iface.sendText.assert_called_once_with(
            "hi", channelIndex=0, destinationId="!aabbccdd", wantAck=True
        )

    def test_invalid_json_is_silently_ignored(self):
        iface = _default_iface()
        msgs = _run_main(
            ["not json at all", '{"action": "quit"}'],
            iface=iface,
        )
        errors = [m for m in msgs if m.get("type") == "error"]
        assert errors == []

    def test_empty_lines_are_ignored(self):
        iface = _default_iface()
        msgs = _run_main(["", "   ", '{"action": "quit"}'], iface=iface)
        errors = [m for m in msgs if m.get("type") == "error"]
        assert errors == []

    def test_nodes_action_emits_nodes(self):
        iface = _default_iface(
            nodes={
                "!00000001": {
                    "num": 1,
                    "user": {"id": "!00000001", "longName": "Node1", "shortName": "N1"},
                    "hopsAway": 0,
                    "lastHeard": 0,
                    "snr": None,
                }
            }
        )
        msgs = _run_main(
            ['{"action": "nodes"}', '{"action": "quit"}'],
            iface=iface,
        )
        nodes_msgs = [m for m in msgs if m.get("type") == "nodes"]
        assert len(nodes_msgs) >= 1
        assert nodes_msgs[-1]["data"][0]["nodeId"] == "!00000001"

    def test_channels_action_emits_channels(self):
        iface = _default_iface()
        iface.localNode.channels = [_make_channel(0, "Primary", 1)]
        msgs = _run_main(
            ['{"action": "channels"}', '{"action": "quit"}'],
            iface=iface,
        )
        ch_msgs = [m for m in msgs if m.get("type") == "channels"]
        assert len(ch_msgs) >= 1
        assert ch_msgs[-1]["data"][0]["name"] == "Primary"

    def test_sendText_exception_emits_error_and_continues(self):
        iface = _default_iface()
        iface.sendText.side_effect = Exception("serial write failed")
        msgs = _run_main(
            ['{"action": "send", "text": "hi", "channel": 0, "id": "cmd-err"}',
             '{"action": "quit"}'],
            iface=iface,
        )
        errors = [m for m in msgs if m.get("type") == "error"]
        assert len(errors) >= 1

    def test_unknown_action_produces_no_output(self):
        iface = _default_iface()
        msgs = _run_main(
            ['{"action": "unknown_cmd"}', '{"action": "quit"}'],
            iface=iface,
        )
        assert msgs == []

    def test_port_is_passed_to_serial_interface(self):
        iface = _default_iface()
        _mock_serial_iface_module.SerialInterface.return_value = iface
        with (
            patch("sys.argv", ["bridge", "/dev/cu.usbserial-0001"]),
            patch("sys.stdin", io.StringIO('{"action": "quit"}\n')),
            patch("sys.stdout", io.StringIO()),
        ):
            bridge.main()
        _mock_serial_iface_module.SerialInterface.assert_called_once_with(
            devPath="/dev/cu.usbserial-0001"
        )


# ===========================================================================
# _on_traceroute
# ===========================================================================


def _traceroute_packet(**overrides):
    """Build a minimal traceroute response packet dict."""
    pkt = {
        "from": 0xAABBCCDD,
        "fromId": "!aabbccdd",
        "requestId": 999,
        "decoded": {
            "portnum": "TRACEROUTE_APP",
            "routeDiscovery": {
                "route": [0x11111111, 0x22222222],
                "snrTowards": [32, 24],   # 8.0 dB, 6.0 dB (scaled ×4)
                "routeBack": [0x22222222, 0x11111111],
                "snrBack": [16, 28],      # 4.0 dB, 7.0 dB
            },
        },
    }
    pkt.update(overrides)
    return pkt


class TestOnTraceroute:
    def test_emits_traceroute_event(self, capsys):
        bridge._pending_traceroutes["!aabbccdd"] = "cmd-42"
        bridge._on_traceroute(_traceroute_packet(), MagicMock())
        msgs = _parse_stdout(capsys)
        assert len(msgs) == 1
        m = msgs[0]
        assert m["type"] == "traceroute"
        assert m["dest"] == "!aabbccdd"
        assert m["id"] == "cmd-42"

    def test_route_nodes_are_converted_to_node_ids(self, capsys):
        bridge._on_traceroute(_traceroute_packet(), MagicMock())
        msgs = _parse_stdout(capsys)
        assert msgs[0]["route"] == ["!11111111", "!22222222"]
        assert msgs[0]["routeBack"] == ["!22222222", "!11111111"]

    def test_snr_values_are_divided_by_four(self, capsys):
        bridge._on_traceroute(_traceroute_packet(), MagicMock())
        msgs = _parse_stdout(capsys)
        assert msgs[0]["snrTowards"] == [8.0, 6.0]
        assert msgs[0]["snrBack"] == [4.0, 7.0]

    def test_removes_pending_entry_after_response(self, capsys):
        bridge._pending_traceroutes["!aabbccdd"] = "cmd-1"
        bridge._on_traceroute(_traceroute_packet(), MagicMock())
        assert "!aabbccdd" not in bridge._pending_traceroutes

    def test_unknown_dest_emits_event_with_none_id(self, capsys):
        # No pending entry for this dest — id should be None.
        bridge._on_traceroute(_traceroute_packet(), MagicMock())
        msgs = _parse_stdout(capsys)
        assert msgs[0]["id"] is None

    def test_empty_route_is_direct_connection(self, capsys):
        pkt = _traceroute_packet()
        pkt["decoded"]["routeDiscovery"] = {"route": [], "routeBack": []}
        bridge._on_traceroute(pkt, MagicMock())
        msgs = _parse_stdout(capsys)
        assert msgs[0]["route"] == []
        assert msgs[0]["routeBack"] == []

    def test_broken_packet_emits_error(self, capsys):
        bridge._on_traceroute(None, MagicMock())
        msgs = _parse_stdout(capsys)
        assert msgs[0]["type"] == "error"


# ===========================================================================
# traceroute action (main loop)
# ===========================================================================


class TestTracerouteAction:
    def test_calls_sendTraceRoute_with_dest_and_hopLimit(self):
        iface = _default_iface()
        _run_main(
            ['{"action": "traceroute", "dest": "!aabbccdd", "hopLimit": 5, "id": "cmd-1"}',
             '{"action": "quit"}'],
            iface=iface,
        )
        iface.sendTraceRoute.assert_called_once_with("!aabbccdd", hopLimit=5)

    def test_stores_pending_entry_keyed_by_dest(self):
        iface = _default_iface()
        # Don't quit immediately so we can inspect state after the action.
        # We patch stdin to send traceroute then quit.
        _run_main(
            ['{"action": "traceroute", "dest": "!aabbccdd", "id": "cmd-99"}',
             '{"action": "quit"}'],
            iface=iface,
        )
        # After main() returns the entry is consumed only by _on_traceroute;
        # since the pubsub callback never fires in the test it stays present.
        assert bridge._pending_traceroutes.get("!aabbccdd") == "cmd-99"

    def test_default_hop_limit_is_seven(self):
        iface = _default_iface()
        _run_main(
            ['{"action": "traceroute", "dest": "!aabbccdd", "id": "cmd-1"}',
             '{"action": "quit"}'],
            iface=iface,
        )
        iface.sendTraceRoute.assert_called_once_with("!aabbccdd", hopLimit=7)

    def test_sendTraceRoute_exception_emits_error(self):
        iface = _default_iface()
        iface.sendTraceRoute.side_effect = Exception("radio busy")
        msgs = _run_main(
            ['{"action": "traceroute", "dest": "!aabbccdd", "id": "cmd-1"}',
             '{"action": "quit"}'],
            iface=iface,
        )
        errors = [m for m in msgs if m.get("type") == "error"]
        assert len(errors) >= 1


# ===========================================================================
# sendposition action (main loop)
# ===========================================================================


class TestSendPositionAction:
    def test_sends_position_with_explicit_coords(self):
        iface = _default_iface()
        _run_main(
            ['{"action": "sendposition", "dest": "!aabbccdd",'
             ' "lat": 40.7128, "lon": -74.0060, "alt": 10, "id": "cmd-1"}',
             '{"action": "quit"}'],
            iface=iface,
        )
        iface.sendPosition.assert_called_once_with(
            latitude=40.7128,
            longitude=-74.0060,
            altitude=10,
            destinationId="!aabbccdd",
            wantAck=True,
        )

    def test_explicit_coords_emit_sent_confirmation(self):
        iface = _default_iface()
        msgs = _run_main(
            ['{"action": "sendposition", "dest": "!aabbccdd",'
             ' "lat": 40.0, "lon": -3.0, "id": "cmd-2"}',
             '{"action": "quit"}'],
            iface=iface,
        )
        sent = [m for m in msgs if m.get("type") == "sent"]
        assert len(sent) == 1
        assert sent[0]["id"] == "cmd-2"

    def test_falls_back_to_device_gps_when_no_coords(self):
        iface = _default_iface()
        iface.getMyNodeInfo.return_value = {
            "user": {"id": "!deadbeef", "longName": "Me", "shortName": "ME"},
            "position": {"latitude": 51.5, "longitude": -0.1, "altitude": 5},
        }
        _run_main(
            ['{"action": "sendposition", "dest": "!aabbccdd", "id": "cmd-3"}',
             '{"action": "quit"}'],
            iface=iface,
        )
        iface.sendPosition.assert_called_once_with(
            latitude=51.5,
            longitude=-0.1,
            altitude=5,
            destinationId="!aabbccdd",
            wantAck=True,
        )

    def test_emits_error_when_no_gps_available(self):
        iface = _default_iface()
        iface.getMyNodeInfo.return_value = {
            "user": {"id": "!deadbeef"},
            "position": {},
        }
        msgs = _run_main(
            ['{"action": "sendposition", "dest": "!aabbccdd", "id": "cmd-4"}',
             '{"action": "quit"}'],
            iface=iface,
        )
        errors = [m for m in msgs if m.get("type") == "error"]
        assert len(errors) >= 1
        assert "gps" in errors[0]["message"].lower() or "position" in errors[0]["message"].lower()

    def test_zero_coordinates_are_accepted(self):
        """Lat/lon 0.0 is a valid position (Gulf of Guinea), not a missing value."""
        iface = _default_iface()
        msgs = _run_main(
            ['{"action": "sendposition", "dest": "!aabbccdd",'
             ' "lat": 0.0, "lon": 0.0, "id": "cmd-5"}',
             '{"action": "quit"}'],
            iface=iface,
        )
        iface.sendPosition.assert_called_once()
        sent = [m for m in msgs if m.get("type") == "sent"]
        assert len(sent) == 1

    def test_sendPosition_exception_emits_error(self):
        iface = _default_iface()
        iface.sendPosition.side_effect = Exception("no fix")
        msgs = _run_main(
            ['{"action": "sendposition", "dest": "!aabbccdd",'
             ' "lat": 40.0, "lon": -3.0, "id": "cmd-6"}',
             '{"action": "quit"}'],
            iface=iface,
        )
        errors = [m for m in msgs if m.get("type") == "error"]
        assert len(errors) >= 1


# ===========================================================================
# _on_telemetry
# ===========================================================================


def _telemetry_packet(**overrides):
    """Build a minimal telemetry packet dict."""
    pkt = {
        "from": 0xAABBCCDD,
        "fromId": "!aabbccdd",
        "decoded": {
            "portnum": "TELEMETRY_APP",
            "telemetry": {
                "deviceMetrics": {
                    "batteryLevel": 85,
                    "voltage": 3.9,
                    "channelUtilization": 5.0,
                    "airUtilTx": 1.0,
                },
                "environmentMetrics": {
                    "temperature": 22.5,
                    "relativeHumidity": 60.0,
                    "barometricPressure": 1013.25,
                },
            },
        },
    }
    pkt.update(overrides)
    return pkt


class TestOnTelemetry:
    def test_emits_telemetry_event(self, capsys):
        bridge._on_telemetry(_telemetry_packet(), MagicMock())
        msgs = _parse_stdout(capsys)
        assert len(msgs) == 1
        m = msgs[0]
        assert m["type"] == "telemetry"
        assert m["from"] == "!aabbccdd"

    def test_device_metrics_are_present(self, capsys):
        bridge._on_telemetry(_telemetry_packet(), MagicMock())
        msgs = _parse_stdout(capsys)
        m = msgs[0]
        assert m["batteryLevel"] == 85
        assert m["voltage"] == pytest.approx(3.9)
        assert m["channelUtilization"] == pytest.approx(5.0)
        assert m["airUtilTx"] == pytest.approx(1.0)

    def test_environment_metrics_are_present(self, capsys):
        bridge._on_telemetry(_telemetry_packet(), MagicMock())
        msgs = _parse_stdout(capsys)
        m = msgs[0]
        assert m["temperature"] == pytest.approx(22.5)
        assert m["relativeHumidity"] == pytest.approx(60.0)
        assert m["barometricPressure"] == pytest.approx(1013.25)

    def test_missing_metrics_are_none(self, capsys):
        pkt = _telemetry_packet()
        pkt["decoded"]["telemetry"] = {}
        bridge._on_telemetry(pkt, MagicMock())
        msgs = _parse_stdout(capsys)
        assert msgs[0]["batteryLevel"] is None
        assert msgs[0]["temperature"] is None

    def test_prefers_fromId_over_from_num(self, capsys):
        pkt = _telemetry_packet(fromId="!cafebabe")
        bridge._on_telemetry(pkt, MagicMock())
        msgs = _parse_stdout(capsys)
        assert msgs[0]["from"] == "!cafebabe"

    def test_falls_back_to_from_num_when_no_fromId(self, capsys):
        pkt = _telemetry_packet()
        del pkt["fromId"]
        bridge._on_telemetry(pkt, MagicMock())
        msgs = _parse_stdout(capsys)
        assert msgs[0]["from"] == "!aabbccdd"

    def test_broken_packet_emits_error(self, capsys):
        bridge._on_telemetry(None, MagicMock())
        msgs = _parse_stdout(capsys)
        assert msgs[0]["type"] == "error"


# ===========================================================================
# _on_node_updated
# ===========================================================================


def _node_updated_payload(**overrides):
    """Build a minimal node dict as passed to _on_node_updated."""
    node = {
        "num": 0xAABBCCDD,
        "user": {
            "id": "!aabbccdd",
            "longName": "Updated Node",
            "shortName": "UN",
        },
        "hopsAway": 2,
        "lastHeard": 1_700_000_000,
        "snr": 6.5,
    }
    node.update(overrides)
    return node


class TestOnNodeUpdated:
    def test_emits_node_updated_event(self, capsys):
        bridge._on_node_updated(_node_updated_payload(), MagicMock())
        msgs = _parse_stdout(capsys)
        assert len(msgs) == 1
        m = msgs[0]
        assert m["type"] == "nodeUpdated"
        assert m["nodeId"] == "!aabbccdd"
        assert m["longName"] == "Updated Node"
        assert m["shortName"] == "UN"

    def test_hops_and_last_heard_are_included(self, capsys):
        bridge._on_node_updated(_node_updated_payload(), MagicMock())
        msgs = _parse_stdout(capsys)
        m = msgs[0]
        assert m["hopsAway"] == 2
        assert m["lastHeard"] == 1_700_000_000
        assert m["snr"] == pytest.approx(6.5)

    def test_node_id_falls_back_to_num(self, capsys):
        node = _node_updated_payload()
        node["user"] = {}
        bridge._on_node_updated(node, MagicMock())
        msgs = _parse_stdout(capsys)
        assert msgs[0]["nodeId"] == "!aabbccdd"

    def test_none_node_emits_no_output(self, capsys):
        bridge._on_node_updated(None, MagicMock())
        assert capsys.readouterr().out == ""

    def test_node_with_no_id_and_zero_num_emits_no_output(self, capsys):
        bridge._on_node_updated({"num": 0, "user": {}}, MagicMock())
        assert capsys.readouterr().out == ""

    def test_broken_node_emits_error(self, capsys):
        class BadNode:
            def get(self, *_a, **_k):
                raise RuntimeError("boom")

        bridge._on_node_updated(BadNode(), MagicMock())
        msgs = _parse_stdout(capsys)
        assert msgs[0]["type"] == "error"
