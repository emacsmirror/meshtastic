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
    from meshtastic.protobuf import mesh_pb2, portnums_pb2
    from pubsub import pub
except ImportError as exc:
    print(json.dumps({"type": "error", "message": f"Import failed: {exc}"}), flush=True)
    sys.exit(1)

BROADCAST_ADDR = "^all"

_iface = None
_out = None  # real stdout while main() runs; the library prints to sys.stdout
_pending_traceroutes: dict = {}  # dest_node_id -> cmd_id


def _emit(obj):
    print(json.dumps(obj), file=_out or sys.stdout, flush=True)


def _packet_id(packet):
    """Return the integer id of a sent MeshPacket, or None."""
    pid = getattr(packet, "id", None)
    return pid if isinstance(pid, int) else None


def _routing_error(packet):
    """Return the routing errorReason of a response PACKET, or None."""
    decoded = (packet or {}).get("decoded", {})
    if decoded.get("portnum") != "ROUTING_APP":
        return None
    return decoded.get("routing", {}).get("errorReason", "NONE")


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
                "replyId": decoded.get("replyId"),
                "emoji": decoded.get("emoji"),
                "relayNode": packet.get("relayNode"),
                "viaMqtt": bool(packet.get("viaMqtt", False)),
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


def _node_dict(node, node_id):
    """Return the JSON representation of NODE identified by NODE_ID.

    hopsAway is None when the firmware does not know the hop count.
    hasPKC is true when the node has published a public key, which
    enables end-to-end encrypted direct messages.
    """
    user = node.get("user", {})
    return {
        "nodeId": node_id,
        "nodeNum": node.get("num"),
        "longName": user.get("longName", ""),
        "shortName": user.get("shortName", ""),
        "hwModel": user.get("hwModel", ""),
        "hasPKC": bool(user.get("publicKey")),
        "hopsAway": node.get("hopsAway"),
        "lastHeard": node.get("lastHeard", 0),
        "snr": node.get("snr"),
    }


def _on_node_updated(node, interface):  # noqa: ARG001
    """Handle a meshtastic.node.updated event."""
    try:
        node = node or {}
        user = node.get("user", {})
        node_id = user.get("id") or _node_id_from_num(node.get("num", 0))
        if not node_id:
            return
        _emit({"type": "nodeUpdated", **_node_dict(node, node_id)})
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
            "firmware": _firmware_version(interface),
        }
    )


def _firmware_version(interface):
    """Return the firmware version reported by INTERFACE, or an empty string."""
    try:
        version = interface.metadata.firmware_version
    except Exception:
        return ""
    return version if isinstance(version, str) else ""


def _send_nodes():
    if _iface is None:
        return
    nodes = []
    try:
        for key, node in (_iface.nodes or {}).items():
            user = node.get("user", {})
            node_id = user.get("id") or (key if isinstance(key, str) else _node_id_from_num(key))
            nodes.append(_node_dict(node, node_id))
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


def _ack_handler(cmd_id):
    """Return a response callback that reports the ACK or NAK for CMD_ID.

    The library only hands plain ACKs to callbacks named onAckNak, and
    sendText() cannot pass onResponseAckPermitted, so the name matters.
    """

    def onAckNak(packet):  # noqa: N802
        try:
            reason = _routing_error(packet)
            if reason is None:
                return
            _emit(
                {
                    "type": "ack",
                    "id": cmd_id,
                    "ok": reason == "NONE",
                    "reason": reason,
                    "from": packet.get("fromId") or _node_id_from_num(packet.get("from")),
                }
            )
        except Exception as exc:
            _emit({"type": "error", "message": f"ACK error: {exc}", "id": cmd_id})

    return onAckNak


def _send_reaction(text, channel, dest, reply_id, cmd_id):
    """Send TEXT as an emoji reaction to the message REPLY_ID.

    sendText() cannot set the emoji flag, so the packet is built by hand.
    """
    packet = mesh_pb2.MeshPacket()
    packet.channel = channel
    packet.decoded.portnum = portnums_pb2.PortNum.TEXT_MESSAGE_APP
    packet.decoded.payload = text.encode("utf-8")
    packet.decoded.emoji = 1
    if reply_id is not None:
        packet.decoded.reply_id = int(reply_id)
    packet.id = _iface._generatePacketId()
    if cmd_id is not None:
        _iface._addResponseHandler(packet.id, _ack_handler(cmd_id), ackPermitted=True)
    return _iface._sendPacket(packet, dest or BROADCAST_ADDR, wantAck=True)


def _cmd_send(cmd):
    """Send a text message or reaction and report its packet id."""
    cmd_id = cmd.get("id")
    text = cmd.get("text", "")
    channel = int(cmd.get("channel", 0))
    dest = cmd.get("dest") or None
    reply_id = cmd.get("replyId")
    if cmd.get("emoji"):
        packet = _send_reaction(text, channel, dest, reply_id, cmd_id)
    else:
        send_kwargs: dict = {"channelIndex": channel, "wantAck": True}
        # Passing destinationId=None crashes the library, so omit it for channels.
        if dest is not None:
            send_kwargs["destinationId"] = dest
        if reply_id is not None:
            send_kwargs["replyId"] = int(reply_id)
        if cmd_id is not None:
            send_kwargs["onResponse"] = _ack_handler(cmd_id)
        packet = _iface.sendText(text, **send_kwargs)
    _emit({"type": "sent", "id": cmd_id, "packetId": _packet_id(packet)})


def _traceroute_handler(dest, cmd_id):
    """Return a response callback that reports a failed traceroute to DEST.

    Successful replies arrive through the meshtastic.receive.traceroute topic.
    """

    def handler(packet):
        reason = _routing_error(packet)
        if reason is None or reason == "NONE":
            return
        _pending_traceroutes.pop(dest, None)
        _emit({"type": "traceroute", "id": cmd_id, "dest": dest, "error": reason})

    return handler


def _cmd_traceroute(cmd):
    """Send a traceroute without blocking the command loop.

    MeshInterface.sendTraceRoute() waits for the reply and prints to
    stdout, so the request is built with sendData() instead.
    """
    dest = cmd.get("dest")
    cmd_id = cmd.get("id")
    if not dest or _iface is None:
        return
    _pending_traceroutes[dest] = cmd_id
    _iface.sendData(
        mesh_pb2.RouteDiscovery(),
        destinationId=dest,
        portNum=portnums_pb2.PortNum.TRACEROUTE_APP,
        wantResponse=True,
        onResponse=_traceroute_handler(dest, cmd_id),
        channelIndex=int(cmd.get("channel", 0)),
        hopLimit=int(cmd.get("hopLimit", 7)),
    )


def _position_handler(dest, cmd_id):
    """Return a response callback that reports the position of DEST."""

    def handler(packet):
        try:
            decoded = packet.get("decoded", {})
            if decoded.get("portnum") == "POSITION_APP":
                pos = decoded.get("position", {})
                lat_i = pos.get("latitudeI")
                lon_i = pos.get("longitudeI")
                _emit(
                    {
                        "type": "position",
                        "id": cmd_id,
                        "from": dest,
                        "lat": lat_i * 1e-7 if lat_i else None,
                        "lon": lon_i * 1e-7 if lon_i else None,
                        "alt": pos.get("altitude"),
                    }
                )
                return
            reason = _routing_error(packet)
            if reason is not None and reason != "NONE":
                _emit({"type": "position", "id": cmd_id, "from": dest, "error": reason})
        except Exception as exc:
            _emit({"type": "error", "message": f"Position error: {exc}", "id": cmd_id})

    return handler


def _cmd_request_position(cmd):
    """Ask a remote node for its position without blocking the command loop."""
    dest = cmd.get("dest")
    cmd_id = cmd.get("id")
    if not dest or _iface is None:
        return
    _iface.sendData(
        mesh_pb2.Position(),
        destinationId=dest,
        portNum=portnums_pb2.PortNum.POSITION_APP,
        wantResponse=True,
        onResponse=_position_handler(dest, cmd_id),
        channelIndex=int(cmd.get("channel", 0)),
    )


def _cmd_send_position(cmd):
    """Send a position to a node, falling back to the device GPS."""
    cmd_id = cmd.get("id")
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
        _emit({"type": "error", "message": "No GPS position available", "id": cmd_id})


_COMMANDS = {
    "send": _cmd_send,
    "nodes": lambda _cmd: _send_nodes(),
    "channels": lambda _cmd: _send_channels(),
    "info": lambda _cmd: _send_info(),
    "traceroute": _cmd_traceroute,
    "requestposition": _cmd_request_position,
    "sendposition": _cmd_send_position,
}


def main():
    global _iface, _out

    port = sys.argv[1] if len(sys.argv) > 1 else None

    # Keep stdout for JSON events only: the meshtastic library prints
    # human-readable text in some code paths, send it to stderr instead.
    _out = sys.stdout
    sys.stdout = sys.stderr

    try:
        _run(port)
    finally:
        sys.stdout = _out
        _out = None


def _run(port):
    global _iface

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
            if action == "quit":
                break
            handler = _COMMANDS.get(action)
            if handler is None:
                continue
            try:
                handler(cmd)
            except Exception as exc:
                _emit({"type": "error", "message": str(exc), "id": cmd.get("id")})
    except Exception as exc:
        _emit({"type": "error", "message": f"Bridge loop error: {exc}"})

    try:
        _iface.close()
    except Exception:
        pass


if __name__ == "__main__":
    main()
