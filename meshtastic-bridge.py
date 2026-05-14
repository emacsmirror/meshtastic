#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Meshtastic JSON bridge for meshtastic.el.

Connects to a Meshtastic device over serial, outputs received messages as
JSON lines to stdout, and accepts JSON commands on stdin.

Usage: python3 meshtastic-bridge.py [/dev/ttyUSB0]
"""

import json
import sys
import time

try:
    import meshtastic
    import meshtastic.serial_interface
    from pubsub import pub
except ImportError as exc:
    print(json.dumps({"type": "error", "message": f"Import failed: {exc}"}),
          flush=True)
    sys.exit(1)

_iface = None


def _emit(obj):
    print(json.dumps(obj), flush=True)


def _node_id_from_num(num):
    if not num:
        return ""
    return f"!{num:08x}"


def _on_receive(packet, interface):  # noqa: ARG001
    try:
        decoded = packet.get("decoded", {})
        if decoded.get("portnum") != "TEXT_MESSAGE_APP":
            return
        from_id = packet.get("fromId") or _node_id_from_num(packet.get("from"))
        to_id = packet.get("toId") or _node_id_from_num(packet.get("to"))
        _emit({
            "type": "message",
            "id": packet.get("id"),
            "from": from_id,
            "to": to_id,
            "text": decoded.get("text", ""),
            "channel": packet.get("channel", 0),
            "rxTime": packet.get("rxTime") or int(time.time()),
            "rxSnr": packet.get("rxSnr"),
            "rxRssi": packet.get("rxRssi"),
            "hopLimit": packet.get("hopLimit"),
            "hopStart": packet.get("hopStart"),
        })
    except Exception as exc:
        _emit({"type": "error", "message": str(exc)})


def _on_connection(interface, topic=pub.AUTO_TOPIC):  # noqa: ARG001
    try:
        my = interface.getMyNodeInfo() or {}
        user = my.get("user", {})
        node_id = user.get("id", "")
        long_name = user.get("longName", "")
        short_name = user.get("shortName", "")
    except Exception:
        try:
            node_num = interface.myInfo.myNodeNum if interface.myInfo else 0
            node_id = _node_id_from_num(node_num)
            node = (interface.nodes or {}).get(node_id, {})
            user = node.get("user", {})
            long_name = user.get("longName", "")
            short_name = user.get("shortName", "")
        except Exception:
            node_id = long_name = short_name = ""
    _emit({
        "type": "connected",
        "nodeId": node_id,
        "longName": long_name,
        "shortName": short_name,
    })


def _send_nodes():
    if _iface is None:
        return
    nodes = []
    try:
        for key, node in (_iface.nodes or {}).items():
            user = node.get("user", {})
            node_id = user.get("id") or (key if isinstance(key, str) else _node_id_from_num(key))
            nodes.append({
                "nodeId": node_id,
                "nodeNum": node.get("num"),
                "longName": user.get("longName", ""),
                "shortName": user.get("shortName", ""),
                "hopsAway": node.get("hopsAway", 0),
                "lastHeard": node.get("lastHeard", 0),
                "snr": node.get("snr"),
            })
    except Exception as exc:
        _emit({"type": "error", "message": str(exc)})
        return
    _emit({"type": "nodes", "data": nodes})


def _send_channels():
    if _iface is None:
        return
    channels = []
    try:
        for ch in _iface.localNode.channels:
            role = int(ch.role) if ch.role is not None else 0
            name = ""
            if ch.settings:
                name = ch.settings.name or ""
            channels.append({
                "index": ch.index,
                "name": name,
                "role": role,
            })
    except Exception as exc:
        _emit({"type": "error", "message": str(exc)})
        return
    _emit({"type": "channels", "data": channels})


def _send_info():
    if _iface is None:
        return
    try:
        my = _iface.getMyNodeInfo() or {}
        user = my.get("user", {})
        _emit({
            "type": "info",
            "nodeId": user.get("id", ""),
            "longName": user.get("longName", ""),
            "shortName": user.get("shortName", ""),
        })
    except Exception as exc:
        _emit({"type": "error", "message": str(exc)})


def main():
    global _iface

    port = sys.argv[1] if len(sys.argv) > 1 else None

    pub.subscribe(_on_receive, "meshtastic.receive.text")
    pub.subscribe(_on_connection, "meshtastic.connection.established")

    try:
        _iface = meshtastic.serial_interface.SerialInterface(devPath=port)
    except Exception as exc:
        _emit({"type": "error", "message": str(exc)})
        sys.exit(1)

    for raw_line in sys.stdin:
        line = raw_line.strip()
        if not line:
            continue
        try:
            cmd = json.loads(line)
        except json.JSONDecodeError:
            continue

        action = cmd.get("action", "")
        cmd_id = cmd.get("id")

        try:
            if action == "send":
                text = cmd.get("text", "")
                channel = int(cmd.get("channel", 0))
                dest = cmd.get("dest") or None
                _iface.sendText(
                    text,
                    channelIndex=channel,
                    destinationId=dest,
                    wantAck=(dest is not None),
                )
                _emit({"type": "sent", "id": cmd_id})
            elif action == "nodes":
                _send_nodes()
            elif action == "channels":
                _send_channels()
            elif action == "info":
                _send_info()
            elif action == "quit":
                break
        except Exception as exc:
            _emit({"type": "error", "message": str(exc), "id": cmd_id})

    try:
        _iface.close()
    except Exception:
        pass


if __name__ == "__main__":
    main()
