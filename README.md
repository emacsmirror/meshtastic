# meshtastic.el

Chat client for [Meshtastic](https://meshtastic.org/) LoRa mesh networks in Emacs, inspired by ERC and rcirc.

Requires Emacs 28.1 or later and the [meshtastic Python package](https://python.meshtastic.org/).

Connects directly to a Meshtastic device over USB serial. No server or intermediate proxy required.

## How it works

```
  LoRa Radio            Python bridge            Emacs
 +-----------+      +-------------------+      +---------------+
 | Meshtastic|<---->| meshtastic-bridge |<---->| meshtastic.el |
 |   Device  | USB  | .py (subprocess)  | JSON | (this package)|
 +-----------+      +-------------------+      +---------------+
   Physical           Reads/writes serial        Chat buffers
   device             Emits JSON events           Send / receive
```

1. A **Meshtastic device** sends and receives messages over LoRa radio.
2. **meshtastic-bridge.py** connects to the device via serial, forwards received messages as JSON lines to stdout, and accepts JSON commands on stdin.
3. **meshtastic.el** spawns the bridge as a subprocess, parses its output, and provides chat buffers.

## Buffers

### Welcome screen (`M-x meshtastic`)

```
  Meshtastic
  ======================================

  Connection
  Port:      /dev/ttyUSB0
  Status:    Connected
  Node:      Hilltop Relay (!a1b2c3d4)

  Statistics
  Nodes:     12
  Channels:  2

  --------------------------------------

  [c] Channels          [n] Nodes
  [g] Refresh           [q] Quit

  --------------------------------------
```

### Channel list (`M-x meshtastic-channels`)

```
  ID  Name          Role
  0   LongFast      Primary
  1   HikingGroup   Secondary
```

### Node list (`M-x meshtastic-nodes`)

```
  Hops  Name                           Node ID         Last heard
  0     🟢 Hilltop Relay               !a1b2c3d4       now
  1     🟢 Solar Node 7                !d4e5f6a7       12m
  2     🟢 BaseStation K9              !b8c9d0e1       5m
  3     ⚫ Mountain Peak               !f2a3b4c5       1h
```

### Chat buffer (channel or DM)

```
[08:15] <Hilltop Relay> Good morning mesh!
[08:20] <BaseStation K9> Morning! Signal is great today
[08:21] <Solar Node 7> Copy that, 3 hops from here
[08:45] <Mountain Peak> Anyone near the trailhead?
[09:02] <Hilltop Relay> I can see 12 nodes from up here
[09:05] <BaseStation K9> Confirmed ✓
[09:30] <River Bridge> Just set up a new repeater
#LongFast> _
```

## Features

- **Channel list**: browse available Meshtastic channels.
- **Node list**: browse all mesh nodes sorted by hop count, with online indicator and last-heard time.
- **Chat buffers**: read and send messages with an ERC-like prompt interface.
- **Direct messages**: open a DM chat with any node by pressing `RET` in the node list.
- **Message buffer**: messages received since the bridge started are kept in memory and shown when a chat buffer opens.
- **Delivery indicator**: sent messages show `·` (sent to bridge), `✓` (bridge confirmed send) or `✗` (failed).
- **Desktop notifications**: get notified when new messages arrive in background buffers.
- **Input history**: navigate previous inputs with `M-p` / `M-n`.
- **Traceroute**: press `t` on a node to send a traceroute via the CLI.

## Keymap

### Channel and node list buffers

| Key   | Description                       |
|-------|-----------------------------------|
| `RET` | Open channel chat or DM with node |
| `0-7` | Open channel by number (channels) |
| `t`   | Send traceroute to node (nodes)   |
| `g`   | Refresh list from device          |
| `q`   | Quit buffer                       |

### Chat buffers

| Key       | Description                  |
|-----------|------------------------------|
| `RET`     | Send message                 |
| `M-p`     | Previous input from history  |
| `M-n`     | Next input from history      |
| `C-c C-l` | Reload buffered messages     |

## Requirements

- Emacs 28.1+
- Python 3 with the meshtastic package:

```sh
pip install meshtastic
```

- A Meshtastic device connected via USB serial.

## Installation

### MELPA

```
M-x package-install RET meshtastic RET
```

### use-package with :vc (Emacs 29+)

```elisp
(use-package meshtastic
  :vc (:url "https://github.com/androsfenollosa/meshtastic.el"
       :rev :newest)
  :config
  (setq meshtastic-serial-port "/dev/ttyUSB0"))
```

### use-package with :load-path

```elisp
(use-package meshtastic
  :load-path "/path/to/meshtastic.el"
  :config
  (setq meshtastic-serial-port "/dev/ttyUSB0"))
```

### Manual

Clone the repository and place the files on your `load-path`:

```sh
git clone https://github.com/androsfenollosa/meshtastic.el.git
```

Add to your init file:

```elisp
(add-to-list 'load-path "/path/to/meshtastic.el")
(require 'meshtastic)
(setq meshtastic-serial-port "/dev/ttyUSB0")
```

## Usage

1. Set `meshtastic-serial-port` to match your device (e.g. `/dev/ttyUSB0` on Linux, `/dev/cu.usbserial-*` on macOS).
2. Run `M-x meshtastic` to open the welcome screen. The bridge starts automatically.
3. Press `c` to browse channels or `n` to browse nodes.
4. Press `RET` on a channel or node to open a chat buffer.
5. Type your message and press `RET` to send.
6. Run `M-x meshtastic-disconnect` to stop the bridge.

## Customization

Run `M-x customize-group RET meshtastic RET` to list all options.

Key options:

- `meshtastic-serial-port` (default `"/dev/ttyUSB0"`): path to the serial device.
- `meshtastic-python-executable` (default `"python3"`): Python binary used to launch the bridge.
- `meshtastic-bridge-script`: path to `meshtastic-bridge.py`, auto-resolved from the package directory.
- `meshtastic-notify` (default `t`): enable desktop notifications (via D-Bus).
- `meshtastic-timestamp-format` (default `"%H:%M"`): format for message timestamps.
- `meshtastic-message-history` (default `200`): number of messages kept in memory per channel or DM.

## Notes

- **No message history on startup**: unlike server-based clients, the bridge has no database. Only messages received since the bridge started are available.
- **LoRa bandwidth**: Meshtastic uses LoRa radio, which has very limited bandwidth. Keep messages short.
- **One device**: each running instance connects to exactly one serial device.

## License

This program is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with this program. If not, see [https://www.gnu.org/licenses/](https://www.gnu.org/licenses/).
