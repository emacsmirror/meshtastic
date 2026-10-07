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
  Node:      Hilltop Relay [HR] (!a1b2c3d4)
  Firmware:  2.7.15.567b8ea
  Uptime:    2h 14m

  Statistics
  Nodes:     12 (7 online)
  Channels:  2
  Messages:  58
  Unread:    3

  ──────────────────────────────────────

  [c] Channels          [n] Nodes
  [d] Direct messages   [u] Unread
  [g] Refresh           [q] Quit

  ──────────────────────────────────────
```

### Channel list (`M-x meshtastic-channels`)

```
  ID  Name          Role         Unread
  0   LongFast      Primary      2
  1   HikingGroup   Secondary
```

### Node list (`M-x meshtastic-nodes`)

```
  Hops  Name                           Node ID         Last heard  Battery
  0     🟢🔑 Hilltop Relay             !a1b2c3d4       now         85%
  1     🟢🔑 Solar Node 7              !d4e5f6a7       12m         -
  2     🟢   BaseStation K9            !b8c9d0e1       5m          62%
  ?     ⚫🔑 Mountain Peak             !f2a3b4c5       1h          -
```

A green dot marks nodes heard in the last 15 minutes. A key marks nodes with a public key, which enables end-to-end encrypted direct messages. `?` means the firmware does not know the hop count; those nodes sort last.

### Direct messages (`M-x meshtastic-direct-messages`)

```
  Time   Name                    Node ID       Unread  Last message
  09:41  Solar Node 7            !d4e5f6a7     1       Battery swapped, all good
  08:12  BaseStation K9          !b8c9d0e1             See you at the summit
```

### Unread (`M-x meshtastic-unread`)

```
  Unread  Conversation              Last message
  2       #LongFast                 Mountain Peak: Anyone near the trailhead?
  1       Solar Node 7              Solar Node 7: Battery swapped, all good
```

### Message info (`C-c C-i` on a message)

```
Message info
════════════════════════

From:       Mountain Peak (!f2a3b4c5)
To:         broadcast
Channel:    LongFast (0)
Time:       2026-10-07 08:45:12
Hops:       2 (start 3, remaining 1)
SNR:        6.25 dB
RSSI:       -97 dBm
Relay node: 0xe1 (BaseStation K9)
Via MQTT:   no
Packet ID:  2934118812

Text
────────────────────────
Anyone near the trailhead?
```

### Traceroute log (`M-x meshtastic-traceroute` or `t` in node list)

```
[08:30:01] → Solar Node 7 (!d4e5f6a7)
  ✓ → Hilltop Relay → BaseStation K9 (8.0dB) → Solar Node 7
  ← Solar Node 7 → BaseStation K9 (7.0dB) → Hilltop Relay

[08:31:15] → Mountain Peak (!f2a3b4c5)
  ⧖ Pending...
```

### Chat buffer (channel or DM)

```
[08:15] <Hilltop Relay> Good morning mesh! ✓
  ↳ 👍 BaseStation K9, ❤ Solar Node 7
[08:20] <BaseStation K9> Morning! Signal is great today
[08:21] <Solar Node 7> ↩ Hilltop Relay: Copy that, 3 hops from here
[08:45] <Mountain Peak> Anyone near the trailhead, Hilltop?
[09:02] <Hilltop Relay> ↩ Mountain Peak: I can see 12 nodes from up here ·
[reply River Bridge] #LongFast> _
```

Your own messages end with a delivery icon. Replies start with `↩` and the name of the answered sender. Reactions are grouped in a `↳` line below the message. Messages that reply to you or mention you are highlighted.

## Features

- **Channel list**: browse available Meshtastic channels, with unread counts.
- **Node list**: browse all mesh nodes sorted by hop count, with online indicator, public key indicator, last-heard time and battery. Press `o` to show only online nodes.
- **Chat buffers**: read and send messages with an ERC-like prompt interface.
- **Direct messages**: open a DM chat with any node by pressing `RET` in the node list, or with the sender of a message with `C-c C-d`. `M-x meshtastic-direct-messages` lists every DM conversation of the session.
- **Unread tracking**: conversations that are not visible count unread messages. `M-x meshtastic-unread` lists them, and the welcome screen shows the total.
- **Replies**: `C-c C-r` answers the message at point. The prompt shows `[reply Name]` until you send, or until `C-c C-k` or `C-g` cancels it.
- **Reactions**: `C-c C-e` reacts with an emoji to the message at point. Uses `emojify-completing-read` when [emojify](https://github.com/iqbalansari/emacs-emojify) is installed.
- **Highlights**: replies to you and mentions of your node name, short name, ID or any word in `meshtastic-keywords` are highlighted, like `erc-match`.
- **Delivery tracking**: sent messages show `·` while waiting, a green `✓` when acknowledged, a yellow `✓` when a DM was heard by the mesh but not confirmed by its recipient, and `✗` when delivery failed. Hover the icon to see the reason.
- **Long messages**: input longer than `meshtastic-max-message-bytes` is split at word boundaries into up to `meshtastic-max-message-parts` messages. The mode line shows the size of what you are typing.
- **Message info**: `C-c C-i` shows sender, recipient, hops, SNR, RSSI, relay node and IDs of the message at point.
- **Notifications**: native notifications on macOS (`terminal-notifier` or `osascript`) and Linux (D-Bus or `notify-send`). Choose between every message or only replies, mentions and DMs with `meshtastic-notify`.
- **Message buffer**: messages received or sent since the bridge started are kept in memory and shown when a chat buffer opens.
- **Input history**: navigate previous inputs with `M-p` / `M-n`.
- **Traceroute**: send a traceroute to a node and see the hop path and SNR values in a dedicated log buffer. Works from the node list (`t`), a DM chat (`M-x meshtastic-traceroute`), or any buffer (prompts for a node).
- **Request position**: ask a node for its current position with `p` in the node list or `M-x meshtastic-request-position`.
- **Send position**: send your GPS coordinates to a node with `P` in the node list or `M-x meshtastic-send-position`. Uses `calendar-latitude` / `calendar-longitude` if set, otherwise falls back to the device GPS.
- **Telemetry**: battery level (and other device metrics) is shown in the Battery column of the node list as percentages arrive from the mesh. Nodes that have not sent telemetry show `-`.
- **Real-time node list**: the node list updates automatically when nodes exchange information on the mesh (new nodes appearing, name or hardware changes), without needing to press `g`.

## Keymap

### Welcome screen

| Key | Description     |
|-----|-----------------|
| `c` | Channels        |
| `n` | Nodes           |
| `d` | Direct messages |
| `u` | Unread          |
| `g` | Refresh         |
| `q` | Quit buffer     |

### List buffers

| Key       | Description                                    |
|-----------|------------------------------------------------|
| `RET`     | Open channel chat, DM or unread conversation   |
| `0-7`     | Open channel by number (channels)              |
| `d`       | Open DM with node (nodes)                      |
| `o`       | Toggle online-only filter (nodes)              |
| `t`       | Send traceroute to node (nodes)                |
| `p`       | Request position from node (nodes)             |
| `P`       | Send your position to node (nodes)             |
| `g`       | Refresh list                                   |
| `q`       | Quit buffer                                    |

### Chat buffers

| Key       | Description                                  |
|-----------|----------------------------------------------|
| `RET`     | Send message                                 |
| `M-p`     | Previous input from history                  |
| `M-n`     | Next input from history                      |
| `C-c C-r` | Reply to the message at point                |
| `C-c C-k` | Cancel the reply                             |
| `C-g`     | Cancel the reply, or quit as usual           |
| `C-c C-e` | React with an emoji to the message at point  |
| `C-c C-s` | Send the message at point again              |
| `C-c C-d` | Open a DM with the sender of the message     |
| `C-c C-i` | Show details of the message at point         |
| `C-c C-l` | Redraw the buffer from buffered messages     |

### Commands available from any buffer

| Command                            | Description                                        |
|------------------------------------|----------------------------------------------------|
| `M-x meshtastic-traceroute`        | Traceroute to a node (uses DM target if in DM)     |
| `M-x meshtastic-request-position`  | Ask a node for its position (uses DM target if in DM) |
| `M-x meshtastic-send-position`     | Send GPS position (uses DM target if in DM)        |
| `M-x meshtastic-direct-messages`   | List DM conversations                              |
| `M-x meshtastic-unread`            | List conversations with unread messages            |

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
  :vc (:url "https://git.andros.dev/andros/meshtastic.el"
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
git clone https://git.andros.dev/andros/meshtastic.el.git
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
3. Press `c` to browse channels, `n` to browse nodes, `d` for direct messages or `u` for unread conversations.
4. Press `RET` on a channel or node to open a chat buffer.
5. Type your message and press `RET` to send.
6. Run `M-x meshtastic-disconnect` to stop the bridge.

## Configuration examples

### Linux, pip

The default configuration works out of the box after `pip install meshtastic`.
Adjust the serial port to match your device:

```elisp
(use-package meshtastic
  :ensure t
  :config
  (setq meshtastic-serial-port "/dev/ttyUSB0"))
```

Find your port with `ls /dev/ttyUSB* /dev/ttyACM*` after plugging in the device.

### macOS, pip

macOS serial ports use a `cu.usbserial-*` naming scheme:

```elisp
(use-package meshtastic
  :ensure t
  :config
  (setq meshtastic-serial-port "/dev/cu.usbserial-0001"))
```

Find your port with `ls /dev/cu.usbserial-*` or `ls /dev/cu.SLAB_USBtoUART*`.

### macOS, uv

If you manage the Python environment with [uv](https://docs.astral.sh/uv/),
clone the repository (it includes a `pyproject.toml` with the `meshtastic`
dependency) and point the executable at `uv run python`:

```sh
git clone https://git.andros.dev/andros/meshtastic.el.git
cd meshtastic.el
uv sync          # creates .venv and installs meshtastic
```

```elisp
(use-package meshtastic
  :load-path "~/path/to/meshtastic.el"
  :config
  (setq meshtastic-serial-port "/dev/cu.usbserial-0001")
  (setq meshtastic-python-executable "/opt/homebrew/bin/uv run python"))
```

`uv run python` resolves the `.venv` from the package directory automatically;
no manual activation is needed.

### Windows

Serial ports on Windows are named `COMn`:

```elisp
(use-package meshtastic
  :ensure t
  :config
  (setq meshtastic-serial-port "COM3")
  (setq meshtastic-python-executable "python"))
```

Check Device Manager under "Ports (COM & LPT)" for the correct number.

## Customization

Run `M-x customize-group RET meshtastic RET` to list all options.

Key options:

- `meshtastic-serial-port` (default `"/dev/ttyUSB0"`): path to the serial device.
- `meshtastic-python-executable` (default `"python3"`): Python binary used to launch the bridge. Supports multi-word values such as `"uv run python"`.
- `meshtastic-bridge-script`: path to `meshtastic-bridge.py`, auto-resolved from the package directory.
- `meshtastic-notify` (default `all`): `nil` never notifies, `highlights` only notifies replies, mentions and DMs, `all` notifies every message in a chat that is not visible.
- `meshtastic-notify-method` (default `native`): `native`, `minibuffer`, `both`, or a function called with `(TITLE BODY TYPE)`.
- `meshtastic-highlight` (default `t`): highlight replies to you and mentions of you.
- `meshtastic-keywords` (default `nil`): extra words that count as a mention of you.
- `meshtastic-timestamp-format` (default `"%H:%M"`): format for message timestamps.
- `meshtastic-message-history` (default `200`): number of messages kept in memory per channel or DM.
- `meshtastic-max-message-bytes` (default `200`): size of a single LoRa message. Longer input is split.
- `meshtastic-max-message-parts` (default `3`): maximum number of messages one input may be split into.
- `meshtastic-online-threshold` (default `900`): seconds since a node was last heard to consider it online.
- `meshtastic-request-timeout` (default `120`): seconds to wait for a traceroute or position reply.

On macOS, install `terminal-notifier` for the best notifications:

```sh
brew install terminal-notifier
```

## Contributing

Bug reports, feature requests and pull requests are welcome. Please read the contribution guidelines before opening an issue or PR:

https://git.andros.dev/andros/contribute

## Development

### Running the tests

Install dev dependencies and run the test suite with [uv](https://docs.astral.sh/uv/):

```sh
uv sync --group dev
uv run pytest
```

Or with pip:

```sh
pip install pytest
pytest
```

The Emacs Lisp tests use ERT and do not need a device:

```sh
emacs --batch -L . -l tests/meshtastic-test.el -f ert-run-tests-batch-and-exit
```

## Notes

- **No message history on startup**: unlike server-based clients, the bridge has no database. Only messages received since the bridge started are available.
- **LoRa bandwidth**: Meshtastic uses LoRa radio, which has very limited bandwidth. Keep messages short: long input is split into several messages, each one using airtime.
- **One device**: each running instance connects to exactly one serial device.

## License

This program is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with this program. If not, see [https://www.gnu.org/licenses/](https://www.gnu.org/licenses/).
