#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026  Andros Fenollosa <hi@andros.dev>
"""Meshtastic JSON bridge for meshtastic.el.

Connects to a Meshtastic device over serial, outputs received messages as
JSON lines to stdout, and accepts JSON commands on stdin.

Usage: python3 meshtastic-bridge.py [/dev/ttyUSB0]
"""

import json
import os
import sys
import time

try:
    import meshtastic
    import meshtastic.serial_interface
    from pubsub import pub
except ImportError as exc:
    print(json.dumps({"type": "error", "message": f"Import failed: {exc}"}), flush=True)
    sys.exit(1)

_iface = None
_pending_traceroutes: dict = {}  # dest_node_id -> cmd_id


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
        _emit(
            {
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
            }
        )
    except Exception as exc:
        _emit({"type": "error", "message": str(exc)})


def _on_telemetry(packet, interface):  # noqa: ARG001
    """Handle an incoming telemetry packet."""
    try:
        from_id = packet.get("fromId") or _node_id_from_num(packet.get("from", 0))
        decoded = packet.get("decoded", {})
        tel = decoded.get("telemetry", {})
        dm = tel.get("deviceMetrics", {})
        em = tel.get("environmentMetrics", {})
        _emit(
            {
                "type": "telemetry",
                "from": from_id,
                "batteryLevel": dm.get("batteryLevel"),
                "voltage": dm.get("voltage"),
                "channelUtilization": dm.get("channelUtilization"),
                "airUtilTx": dm.get("airUtilTx"),
                "temperature": em.get("temperature"),
                "relativeHumidity": em.get("relativeHumidity"),
                "barometricPressure": em.get("barometricPressure"),
            }
        )
    except Exception as exc:
        _emit({"type": "error", "message": f"Telemetry error: {exc}"})


def _on_node_updated(node, interface):  # noqa: ARG001
    """Handle a meshtastic.node.updated event."""
    try:
        user = (node or {}).get("user", {})
        node_id = user.get("id") or _node_id_from_num((node or {}).get("num", 0))
        if not node_id:
            return
        _emit(
            {
                "type": "nodeUpdated",
                "nodeId": node_id,
                "nodeNum": (node or {}).get("num"),
                "longName": user.get("longName", ""),
                "shortName": user.get("shortName", ""),
                "hopsAway": (node or {}).get("hopsAway", 0),
                "lastHeard": (node or {}).get("lastHeard", 0),
                "snr": (node or {}).get("snr"),
            }
        )
    except Exception as exc:
        _emit({"type": "error", "message": f"Node updated error: {exc}"})


def _on_traceroute(packet, interface):  # noqa: ARG001
    """Handle an incoming traceroute response."""
    try:
        from_id = packet.get("fromId") or _node_id_from_num(packet.get("from", 0))
        cmd_id = _pending_traceroutes.pop(from_id, None)
        decoded = packet.get("decoded", {})
        rd = decoded.get("routeDiscovery", {})
        route = [_node_id_from_num(n) for n in (rd.get("route") or [])]
        route_back = [_node_id_from_num(n) for n in (rd.get("routeBack") or [])]
        # SNR values are stored scaled by 4 (0.25 dB resolution)
        snr_towards = [(v / 4.0) for v in (rd.get("snrTowards") or [])]
        snr_back = [(v / 4.0) for v in (rd.get("snrBack") or [])]
        _emit(
            {
                "type": "traceroute",
                "id": cmd_id,
                "dest": from_id,
                "route": route,
                "routeBack": route_back,
                "snrTowards": snr_towards,
                "snrBack": snr_back,
            }
        )
    except Exception as exc:
        _emit({"type": "error", "message": f"Traceroute error: {exc}"})


def _on_disconnect(interface, topic=pub.AUTO_TOPIC):  # noqa: ARG001
    _emit({"type": "error", "message": "Device disconnected"})
    try:
        interface.close()
    except Exception:
        pass
    # os._exit terminates the whole process from any thread.
    # sys.exit() only raises SystemExit in the calling thread (the meshtastic
    # reader thread), leaving the main stdin loop blocked indefinitely.
    os._exit(0)


def _on_connection(interface, topic=pub.AUTO_TOPIC):  # noqa: ARG001
    try:
        my = interface.getMyNodeInfo() or {}
        user = my.get("user", {})
        node_id = user.get("id", "")
        long_name = user.get("longName", "")
        short_name = user.get("shortName", "")
    except Exception:
        try:
            node_num = interface.myInfo.my_node_num if interface.myInfo else 0
            node_id = _node_id_from_num(node_num)
            node = (interface.nodes or {}).get(node_id, {})
            user = node.get("user", {})
            long_name = user.get("longName", "")
            short_name = user.get("shortName", "")
        except Exception:
            node_id = long_name = short_name = ""
    _emit(
        {
            "type": "connected",
            "nodeId": node_id,
            "longName": long_name,
            "shortName": short_name,
        }
    )


def _send_nodes():
    if _iface is None:
        return
    nodes = []
    try:
        for key, node in (_iface.nodes or {}).items():
            user = node.get("user", {})
            node_id = user.get("id") or (key if isinstance(key, str) else _node_id_from_num(key))
            nodes.append(
                {
                    "nodeId": node_id,
                    "nodeNum": node.get("num"),
                    "longName": user.get("longName", ""),
                    "shortName": user.get("shortName", ""),
                    "hopsAway": node.get("hopsAway", 0),
                    "lastHeard": node.get("lastHeard", 0),
                    "snr": node.get("snr"),
                }
            )
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
            channels.append(
                {
                    "index": ch.index,
                    "name": name,
                    "role": role,
                }
            )
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
        _emit(
            {
                "type": "info",
                "nodeId": user.get("id", ""),
                "longName": user.get("longName", ""),
                "shortName": user.get("shortName", ""),
            }
        )
    except Exception as exc:
        _emit({"type": "error", "message": str(exc)})


def main():
    global _iface

    port = sys.argv[1] if len(sys.argv) > 1 else None

    pub.subscribe(_on_receive, "meshtastic.receive.text")
    pub.subscribe(_on_telemetry, "meshtastic.receive.telemetry")
    pub.subscribe(_on_traceroute, "meshtastic.receive.traceroute")
    pub.subscribe(_on_node_updated, "meshtastic.node.updated")
    pub.subscribe(_on_connection, "meshtastic.connection.established")
    pub.subscribe(_on_disconnect, "meshtastic.connection.lost")

    try:
        _iface = meshtastic.serial_interface.SerialInterface(devPath=port)
    except Exception as exc:
        _emit({"type": "error", "message": str(exc)})
        sys.exit(1)

    try:
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
                    send_kwargs: dict = {
                        "channelIndex": channel,
                        "wantAck": dest is not None,
                    }
                    if dest is not None:
                        send_kwargs["destinationId"] = dest
                    _iface.sendText(text, **send_kwargs)
                    _emit({"type": "sent", "id": cmd_id})
                elif action == "nodes":
                    _send_nodes()
                elif action == "channels":
                    _send_channels()
                elif action == "info":
                    _send_info()
                elif action == "traceroute":
                    dest = cmd.get("dest")
                    hop_limit = int(cmd.get("hopLimit", 7))
                    if dest and _iface:
                        _pending_traceroutes[dest] = cmd_id
                        _iface.sendTraceRoute(dest, hopLimit=hop_limit)
                elif action == "sendposition":
                    dest = cmd.get("dest")
                    lat = cmd.get("lat")
                    lon = cmd.get("lon")
                    alt = cmd.get("alt", 0)
                    if (lat is None or lon is None) and _iface:
                        try:
                            my_info = _iface.getMyNodeInfo() or {}
                            pos = my_info.get("position") or {}
                            lat = pos.get("latitude")
                            lon = pos.get("longitude")
                            alt = pos.get("altitude", 0)
                        except Exception:
                            pass
                    if lat is not None and lon is not None and _iface and dest:
                        _iface.sendPosition(
                            latitude=float(lat),
                            longitude=float(lon),
                            altitude=int(alt or 0),
                            destinationId=dest,
                            wantAck=True,
                        )
                        _emit({"type": "sent", "id": cmd_id})
                    else:
                        _emit(
                            {
                                "type": "error",
                                "message": "No GPS position available",
                                "id": cmd_id,
                            }
                        )
                elif action == "quit":
                    break
            except Exception as exc:
                _emit({"type": "error", "message": str(exc), "id": cmd_id})
    except Exception as exc:
        _emit({"type": "error", "message": f"Bridge loop error: {exc}"})

    try:
        _iface.close()
    except Exception:
        pass


if __name__ == "__main__":
    main()
