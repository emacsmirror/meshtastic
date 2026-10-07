;;; meshtastic.el --- Chat client for Meshtastic LoRa devices via serial  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Andros Fenollosa

;; Author: Andros Fenollosa <hi@andros.dev>
;; Maintainer: Andros Fenollosa <hi@andros.dev>
;; Version: 1.2.0
;; Package-Requires: ((emacs "28.1"))
;; Keywords: comm
;; URL: https://git.andros.dev/andros/meshtastic.el

;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is NOT part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Emacs chat client for Meshtastic LoRa mesh networks.
;; Connects to a Meshtastic device over serial USB via a Python bridge.
;;
;; Requires the meshtastic Python package:
;;   pip install meshtastic
;;
;; Configure `meshtastic-serial-port' in your init file, then:
;;
;;   M-x meshtastic                 - welcome screen
;;   M-x meshtastic-channels        - list channels
;;   M-x meshtastic-nodes           - list nodes by hops
;;   M-x meshtastic-direct-messages - list DM conversations
;;   M-x meshtastic-unread          - conversations with unread messages
;;
;; Messages received since the bridge started are buffered in memory
;; and shown when a chat buffer is opened.

;;; Code:

(require 'json)
(require 'cl-lib)
(require 'notifications)
(require 'ring)
(require 'seq)

;;;; Customization

(defgroup meshtastic nil
  "Chat client for Meshtastic LoRa mesh networks."
  :group 'communication
  :prefix "meshtastic-")

(defcustom meshtastic-serial-port "/dev/ttyUSB0"
  "Serial port path for the Meshtastic device."
  :type 'string
  :group 'meshtastic)

(defcustom meshtastic-python-executable "python3"
  "Python executable used to launch the bridge script.
See also `python-shell-interpreter'."
  :type 'string
  :group 'meshtastic)

(defcustom meshtastic-bridge-script
  (expand-file-name
   "meshtastic-bridge.py"
   (file-name-directory
    (or load-file-name
        (locate-library "meshtastic")
        "")))
  "Absolute path to meshtastic-bridge.py."
  :type 'file
  :group 'meshtastic)

(defcustom meshtastic-notify 'all
  "Control notifications for incoming messages.
Possible values:

- nil          Never notify.
- `highlights' Only notify for replies to you, mentions of you and
               direct messages, unless the chat is the selected window.
- `all' (or t) Notify for every message in a chat that is not visible.

Inspired by `erc-notifications-mode'."
  :type '(choice (const :tag "Never" nil)
                 (const :tag "Only replies, mentions and DMs" highlights)
                 (const :tag "All messages" all))
  :group 'meshtastic)

(defcustom meshtastic-notify-method 'native
  "How to deliver notifications selected by `meshtastic-notify'.
Possible values:

- `native'     Show a native operating-system notification.  On macOS
               this uses `terminal-notifier' when available, otherwise
               `osascript'.  On other systems it uses the D-Bus
               `notifications' library or the `notify-send' command.
- `minibuffer' Show the notification in the echo area.
- `both'       Use both the native and minibuffer methods.
- a function   Called with (TITLE BODY TYPE) to deliver the
               notification yourself.  TYPE is one of `reply',
               `mention', `dm' or `message'."
  :type '(choice (const :tag "Native OS notification" native)
                 (const :tag "Echo area (minibuffer)" minibuffer)
                 (const :tag "Both native and echo area" both)
                 (function :tag "Custom function"))
  :group 'meshtastic)

(defcustom meshtastic-highlight t
  "Non-nil means highlight replies to you and mentions of you.
Highlighted messages use `meshtastic-highlight-face', regardless of
the notification settings.  Analogous to the `erc-match' module."
  :type 'boolean
  :group 'meshtastic)

(defcustom meshtastic-keywords nil
  "Extra words that count as a mention of you.
Matching is case-insensitive.  Similar to `erc-keywords'.  Your node
long name, short name and ID are always treated as mentions."
  :type '(repeat string)
  :group 'meshtastic)

(defcustom meshtastic-timestamp-format "%H:%M"
  "Format string for message timestamps, passed to `format-time-string'."
  :type 'string
  :group 'meshtastic)

(defcustom meshtastic-message-history 200
  "Number of messages to keep in memory per channel or DM."
  :type 'integer
  :group 'meshtastic)

(defcustom meshtastic-max-message-bytes 200
  "Maximum size in bytes of a single LoRa text message.
Longer input is split into several messages of at most this size.
The firmware rejects payloads over 233 bytes."
  :type 'integer
  :group 'meshtastic)

(defcustom meshtastic-max-message-parts 3
  "Maximum number of messages a single input may be split into.
Input longer than `meshtastic-max-message-bytes' times this value
is refused, to avoid flooding the mesh."
  :type 'integer
  :group 'meshtastic)

(defcustom meshtastic-online-threshold 900
  "Seconds since a node was last heard to consider it online."
  :type 'integer
  :group 'meshtastic)

(defcustom meshtastic-request-timeout 120
  "Seconds to wait for a traceroute or position reply."
  :type 'integer
  :group 'meshtastic)

;;;; Faces

(defface meshtastic-timestamp-face
  '((t :foreground "gray50"))
  "Face for message timestamps."
  :group 'meshtastic)

(defface meshtastic-nick-self-face
  '((t :foreground "sea green" :weight bold))
  "Face for the local node nick in messages."
  :group 'meshtastic)

(defface meshtastic-nick-other-face
  '((t :foreground "dodger blue" :weight bold))
  "Face for remote node nicks in messages."
  :group 'meshtastic)

(defface meshtastic-prompt-face
  '((t :foreground "cyan" :weight bold))
  "Face for the input prompt."
  :group 'meshtastic)

(defface meshtastic-system-face
  '((t :foreground "gray60" :slant italic))
  "Face for system messages."
  :group 'meshtastic)

(defface meshtastic-delivery-pending-face
  '((t :foreground "gray50"))
  "Face for the pending delivery indicator."
  :group 'meshtastic)

(defface meshtastic-delivery-relayed-face
  '((t :foreground "dark khaki"))
  "Face for a message heard by the mesh but not confirmed by its recipient."
  :group 'meshtastic)

(defface meshtastic-delivery-confirmed-face
  '((t :foreground "green"))
  "Face for the confirmed delivery indicator."
  :group 'meshtastic)

(defface meshtastic-delivery-failed-face
  '((t :foreground "red"))
  "Face for the failed delivery indicator."
  :group 'meshtastic)

(defface meshtastic-highlight-face
  '((t :weight bold :inherit highlight))
  "Face for messages that reply to you or mention you.
Analogous to `erc-current-nick-face'."
  :group 'meshtastic)

(defface meshtastic-welcome-title-face
  '((t :weight bold :height 1.3))
  "Face for the title in the welcome buffer."
  :group 'meshtastic)

(defface meshtastic-welcome-heading-face
  '((t :weight bold))
  "Face for section headings in the welcome buffer."
  :group 'meshtastic)

(defface meshtastic-welcome-key-face
  '((t :foreground "cyan" :weight bold))
  "Face for keyboard shortcuts in the welcome buffer."
  :group 'meshtastic)

;;;; Internal state

(defvar meshtastic--process nil
  "The bridge subprocess, or nil when stopped.")

(defvar meshtastic--connected nil
  "Non-nil when the bridge has confirmed connection to the device.")

(defvar meshtastic--connected-since nil
  "Time value of the last successful connection, or nil.")

(defvar meshtastic--my-node-id nil
  "Node ID string of the local device, e.g. \"!deadbeef\".")

(defvar meshtastic--my-long-name nil
  "Long name of the local device as reported by the firmware.")

(defvar meshtastic--my-short-name nil
  "Short name of the local device as reported by the firmware.")

(defvar meshtastic--firmware nil
  "Firmware version string of the local device, or nil.")

(defvar meshtastic--nodes (make-hash-table :test 'equal)
  "Hash table mapping node ID strings to node alists.")

(defvar meshtastic--channels nil
  "List of channel alists fetched from the device.")

(defvar meshtastic--chat-buffers nil
  "Alist of ((TYPE . TARGET) . BUFFER) for open chat buffers.")

(defvar meshtastic--message-rings (make-hash-table :test 'equal)
  "Hash table mapping (TYPE . TARGET) cons to a ring of message alists.")

(defvar meshtastic--unread (make-hash-table :test 'equal)
  "Hash table mapping (TYPE . TARGET) cons to its unread message count.")

(defvar meshtastic--cmd-counter 0
  "Monotonic counter for generating unique command IDs.")

(defvar meshtastic--outgoing (make-hash-table :test 'equal)
  "Hash table mapping cmd-id to (MSG TTYPE TARGET) for unconfirmed sends.
MSG is the message alist stored in the ring, updated in place when the
bridge reports its packet id and acknowledgement.")

(defvar meshtastic--my-packet-ids (make-hash-table :test 'eql)
  "Hash table of packet ids sent by the local node.
Used to detect replies directed at you.")

(defvar meshtastic--traceroute-entries (make-hash-table :test 'equal)
  "Hash table mapping cmd-id to (status-start-marker . status-end-marker).")

(defvar meshtastic--request-timers (make-hash-table :test 'equal)
  "Hash table mapping cmd-id to the timeout timer of a pending request.")

(defvar meshtastic--telemetry (make-hash-table :test 'equal)
  "Hash table mapping node ID strings to their latest telemetry alist.")

;;;; Buffer-local variables

(defvar-local meshtastic--target nil
  "Target for this chat buffer: channel index (integer) or node ID (string).")

(defvar-local meshtastic--target-type nil
  "Target type for this chat buffer: symbol `channel' or `dm'.")

(defvar-local meshtastic--prompt-start nil
  "Marker at the start of the input prompt.")

(defvar-local meshtastic--prompt-end nil
  "Marker at the end of the input prompt (start of user input).")

(defvar-local meshtastic--seen-ids nil
  "Hash table of rendered message keys used for deduplication.")

(defvar-local meshtastic--input-ring nil
  "Ring of previous input strings for history navigation.")

(defvar-local meshtastic--input-ring-index 0
  "Current position in `meshtastic--input-ring'.")

(defvar-local meshtastic--delivery-markers nil
  "Alist of (CMD-ID . MARKER) for messages awaiting acknowledgement.")

(defvar-local meshtastic--reply-to nil
  "Cons of (PACKET-ID . SENDER-NAME) for the message being replied to.")

(defvar-local meshtastic--reactions nil
  "Hash table mapping a packet id to a list of (EMOJI . SENDER) pairs.")

(defvar-local meshtastic--node-list-online-only nil
  "Non-nil means the node list shows only online nodes.")

;;;; Timestamp helpers

(defun meshtastic--format-time (ts)
  "Format unix timestamp TS using `meshtastic-timestamp-format'."
  (condition-case nil
      (format-time-string meshtastic-timestamp-format
                          (seconds-to-time ts))
    (error "??:??")))

(defun meshtastic--format-last-heard (ts)
  "Format last-heard unix timestamp TS as a relative string."
  (if (and ts (numberp ts) (> ts 0))
      (let* ((secs (- (float-time) ts))
             (mins (/ secs 60))
             (hours (/ mins 60))
             (days (/ hours 24)))
        (cond
         ((< mins 1) "now")
         ((< mins 60) (format "%dm" (truncate mins)))
         ((< hours 24) (format "%dh" (truncate hours)))
         (t (format "%dd" (truncate days)))))
    "?"))

(defun meshtastic--format-duration (seconds)
  "Format SECONDS as a short human-readable duration."
  (let* ((seconds (truncate seconds))
         (days (/ seconds 86400))
         (hours (/ (% seconds 86400) 3600))
         (mins (/ (% seconds 3600) 60)))
    (cond
     ((> days 0) (format "%dd %dh" days hours))
     ((> hours 0) (format "%dh %dm" hours mins))
     (t (format "%dm" mins)))))

(defun meshtastic--node-online-p (last-heard)
  "Return non-nil if LAST-HEARD is within `meshtastic-online-threshold'."
  (and last-heard (numberp last-heard) (> last-heard 0)
       (< (- (float-time) last-heard) meshtastic-online-threshold)))

;;;; Node and channel helpers

(defun meshtastic--json-true-p (value)
  "Return non-nil if JSON VALUE is true.
Handles the `json-read' representation where false is `:json-false'."
  (and value (not (eq value :json-false))))

(defun meshtastic--node-name (id)
  "Return a display name for node ID, falling back to ID itself."
  (let ((node (and id (gethash id meshtastic--nodes))))
    (cond
     ((and (not node) id (equal id meshtastic--my-node-id)
           meshtastic--my-long-name
           (not (string-empty-p meshtastic--my-long-name)))
      meshtastic--my-long-name)
     (node
      (let ((long (alist-get 'longName node))
            (short (alist-get 'shortName node)))
        (cond
         ((and long (not (string-empty-p long))) long)
         ((and short (not (string-empty-p short))) short)
         (t (format "%s" id)))))
     (t (format "%s" (or id "?"))))))

(defun meshtastic--node-has-pkc-p (node-id)
  "Return non-nil if NODE-ID has published a public key."
  (let ((node (gethash node-id meshtastic--nodes)))
    (and node (meshtastic--json-true-p (alist-get 'hasPKC node)))))

(defun meshtastic--channel-name (index)
  "Return the name for channel INDEX, falling back to its number."
  (let ((ch (seq-find (lambda (c) (equal (alist-get 'index c) index))
                      meshtastic--channels)))
    (if ch
        (let ((name (alist-get 'name ch)))
          (if (and name (not (string-empty-p name)))
              name
            (format "%d" index)))
      (format "%d" index))))

(defun meshtastic--target-name (ttype target)
  "Return a display name for conversation TTYPE and TARGET."
  (pcase ttype
    ('channel (format "#%s" (meshtastic--channel-name target)))
    ('dm (meshtastic--node-name target))
    (_ "Meshtastic")))

(defun meshtastic--active-channels ()
  "Return the channels that are not disabled."
  (seq-filter (lambda (c) (> (or (alist-get 'role c) 0) 0))
              meshtastic--channels))

(defun meshtastic--node-count ()
  "Return the number of nodes in the in-memory cache."
  (hash-table-count meshtastic--nodes))

(defun meshtastic--online-node-count ()
  "Return the number of cached nodes considered online."
  (let ((count 0))
    (maphash (lambda (_id node)
               (when (meshtastic--node-online-p (alist-get 'lastHeard node))
                 (cl-incf count)))
             meshtastic--nodes)
    count))

(defun meshtastic--is-self-p (msg)
  "Return non-nil if MSG was sent by the local device."
  (let ((from (alist-get 'from msg)))
    (and meshtastic--my-node-id from
         (equal from meshtastic--my-node-id))))

(defun meshtastic--reaction-p (msg)
  "Return non-nil if MSG is an emoji reaction to another message."
  (let ((emoji (alist-get 'emoji msg)))
    (and (numberp emoji) (/= emoji 0)
         (alist-get 'replyId msg))))

(defun meshtastic--broadcast-p (to-id)
  "Return non-nil if TO-ID represents a broadcast address."
  (or (null to-id)
      (string-empty-p to-id)
      (string= to-id "!ffffffff")
      (string= to-id "^all")
      (string= to-id "4294967295")))

;;;; Message ring buffer

(defun meshtastic--ring-push (ttype target msg)
  "Append MSG to the in-memory ring for TTYPE and TARGET."
  (let* ((key (cons ttype target))
         (ring (or (gethash key meshtastic--message-rings)
                   (puthash key (make-ring meshtastic-message-history)
                            meshtastic--message-rings))))
    (ring-insert ring msg)))

(defun meshtastic--ring-messages (ttype target)
  "Return all buffered messages for TTYPE and TARGET in chronological order."
  (let ((ring (gethash (cons ttype target) meshtastic--message-rings))
        (msgs nil))
    (when ring
      (dotimes (i (ring-length ring))
        (push (ring-ref ring i) msgs)))
    msgs))

(defun meshtastic--last-text-message (ttype target)
  "Return the most recent non-reaction message for TTYPE and TARGET."
  (car (last (seq-remove #'meshtastic--reaction-p
                         (meshtastic--ring-messages ttype target)))))

(defun meshtastic--message-count ()
  "Return the number of messages buffered in memory."
  (let ((count 0))
    (maphash (lambda (_key ring) (cl-incf count (ring-length ring)))
             meshtastic--message-rings)
    count))

;;;; Unread tracking

(defun meshtastic--unread-total ()
  "Return the total number of unread messages."
  (let ((total 0))
    (maphash (lambda (_key n) (cl-incf total n)) meshtastic--unread)
    total))

(defun meshtastic--mark-unread (ttype target)
  "Count one more unread message for TTYPE and TARGET."
  (let ((key (cons ttype target)))
    (puthash key (1+ (gethash key meshtastic--unread 0)) meshtastic--unread)))

(defun meshtastic--mark-read (ttype target)
  "Mark the conversation TTYPE and TARGET as read."
  (let ((key (cons ttype target)))
    (when (gethash key meshtastic--unread)
      (remhash key meshtastic--unread)
      (meshtastic--refresh-views))))

(defun meshtastic--on-window-display (window)
  "Mark the chat buffer shown in WINDOW as read."
  (with-current-buffer (window-buffer window)
    (when meshtastic--target-type
      (meshtastic--mark-read meshtastic--target-type meshtastic--target))))

;;;; Process management

(defun meshtastic--cmd-id ()
  "Return a fresh unique command ID string."
  (format "cmd-%d" (cl-incf meshtastic--cmd-counter)))

(defun meshtastic--send-cmd (alist)
  "Serialize ALIST as JSON and send it to the bridge stdin."
  (when (and meshtastic--process
             (process-live-p meshtastic--process))
    (process-send-string
     meshtastic--process
     (concat (json-encode alist) "\n"))))

(defun meshtastic--process-filter (proc string)
  "Accumulate STRING from bridge PROC and dispatch complete JSON lines."
  (let* ((buf (concat (or (process-get proc 'partial) "") string))
         (lines (split-string buf "\n")))
    (process-put proc 'partial (car (last lines)))
    (dolist (line (butlast lines))
      (unless (string-empty-p (string-trim line))
        (meshtastic--handle-line line)))))

(defun meshtastic--process-sentinel (proc event)
  "Handle bridge PROC lifecycle EVENT."
  (unless (process-live-p proc)
    (when (eq meshtastic--process proc)
      (setq meshtastic--connected nil
            meshtastic--process nil)
      (message "Meshtastic: bridge stopped (%s)" (string-trim event))
      (meshtastic--fail-all-outgoing "bridge stopped")
      (dolist (entry meshtastic--chat-buffers)
        (let ((buf (cdr entry)))
          (when (buffer-live-p buf)
            (meshtastic--insert-msg buf nil nil
                                    "Bridge disconnected" nil t))))
      (meshtastic--refresh-views))))

(defun meshtastic--handle-line (line)
  "Parse a JSON LINE from the bridge and dispatch to the correct handler."
  (let ((obj (condition-case nil
                 (let ((json-object-type 'alist)
                       (json-array-type 'list)
                       (json-key-type 'symbol))
                   (json-read-from-string line))
               (error nil))))
    (if (not (consp obj))
        (message "Meshtastic bridge: %s" line)
      (pcase (alist-get 'type obj)
        ("connected"   (meshtastic--on-connected obj))
        ("message"     (meshtastic--on-message obj))
        ("nodes"       (meshtastic--on-nodes obj))
        ("channels"    (meshtastic--on-channels obj))
        ("info"        (meshtastic--on-info obj))
        ("sent"        (meshtastic--on-sent obj))
        ("ack"         (meshtastic--on-ack obj))
        ("traceroute"  (meshtastic--on-traceroute obj))
        ("position"    (meshtastic--on-position obj))
        ("telemetry"   (meshtastic--on-telemetry obj))
        ("nodeUpdated" (meshtastic--on-node-updated obj))
        ("error"       (meshtastic--on-error obj))))))

(defun meshtastic--start ()
  "Launch the Python bridge subprocess."
  (when (and meshtastic--process (process-live-p meshtastic--process))
    (delete-process meshtastic--process))
  (unless (file-exists-p meshtastic-bridge-script)
    (user-error "Bridge script not found: %s" meshtastic-bridge-script))
  (let ((default-directory (file-name-directory meshtastic-bridge-script)))
    (setq meshtastic--process
          (make-process
           :name "meshtastic-bridge"
           :command (append (split-string meshtastic-python-executable)
                            (list "-u"
                                  meshtastic-bridge-script
                                  meshtastic-serial-port))
           :filter #'meshtastic--process-filter
           :sentinel #'meshtastic--process-sentinel
           :connection-type 'pipe
           :noquery t)))
  (message "Meshtastic: connecting on %s..." meshtastic-serial-port))

(defun meshtastic--ensure-connected ()
  "Start the bridge if it is not already running."
  (when (string-empty-p meshtastic-serial-port)
    (user-error "Set `meshtastic-serial-port' in your init file"))
  (unless (and meshtastic--process
               (process-live-p meshtastic--process))
    (meshtastic--start)))

;;;; Bridge event handlers

(defun meshtastic--on-connected (obj)
  "Handle a connected event OBJ from the bridge."
  (setq meshtastic--connected t
        meshtastic--connected-since (current-time)
        meshtastic--my-node-id (alist-get 'nodeId obj)
        meshtastic--my-long-name (alist-get 'longName obj)
        meshtastic--my-short-name (alist-get 'shortName obj)
        meshtastic--firmware (let ((fw (alist-get 'firmware obj)))
                               (and fw (not (string-empty-p fw)) fw)))
  (meshtastic--send-cmd '((action . "channels")))
  (meshtastic--send-cmd '((action . "nodes")))
  (message "Meshtastic: connected as %s (%s)"
           (or meshtastic--my-long-name "?")
           (or meshtastic--my-node-id "?"))
  (meshtastic--refresh-views))

(defun meshtastic--message-target (obj)
  "Return (TTYPE . TARGET) of the conversation incoming message OBJ belongs to."
  (if (meshtastic--broadcast-p (alist-get 'to obj))
      (cons 'channel (or (alist-get 'channel obj) 0))
    (cons 'dm (alist-get 'from obj))))

(defun meshtastic--on-message (obj)
  "Handle an incoming message OBJ from the bridge."
  (pcase-let* ((`(,ttype . ,target) (meshtastic--message-target obj))
               (buf (meshtastic--chat-buffer ttype target))
               (reaction (meshtastic--reaction-p obj)))
    (meshtastic--ring-push ttype target obj)
    (unless (or reaction (meshtastic--is-self-p obj)
                (and buf (get-buffer-window buf t)))
      (meshtastic--mark-unread ttype target))
    (if buf
        ;; Rendering also takes care of notifications.
        (meshtastic--render-messages buf (list obj))
      (unless reaction
        (meshtastic--maybe-notify
         nil ttype target (meshtastic--node-name (alist-get 'from obj))
         (or (alist-get 'text obj) "")
         (meshtastic--highlight-type obj ttype))))
    (meshtastic--refresh-views)))

(defun meshtastic--on-nodes (obj)
  "Handle a nodes data OBJ from the bridge."
  (let ((data (alist-get 'data obj)))
    (when (listp data)
      (clrhash meshtastic--nodes)
      (dolist (node data)
        (let ((id (alist-get 'nodeId node)))
          (when (and id (not (string-empty-p id)))
            (puthash id node meshtastic--nodes))))))
  (meshtastic--refresh-node-list)
  (meshtastic--refresh-views))

(defun meshtastic--on-channels (obj)
  "Handle a channels data OBJ from the bridge."
  (setq meshtastic--channels (alist-get 'data obj))
  (let ((buf (get-buffer "*Meshtastic: Channels*")))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (meshtastic--populate-channel-list))))
  (meshtastic--refresh-views))

(defun meshtastic--on-info (obj)
  "Handle a device info OBJ from the bridge."
  (setq meshtastic--my-node-id (alist-get 'nodeId obj)
        meshtastic--my-long-name (alist-get 'longName obj)
        meshtastic--my-short-name (alist-get 'shortName obj)))

(defun meshtastic--on-sent (obj)
  "Handle a sent confirmation OBJ from the bridge.
The message has been handed to the radio; its packet id is recorded
so that replies and reactions can reference it."
  (let* ((entry (gethash (alist-get 'id obj) meshtastic--outgoing))
         (packet-id (alist-get 'packetId obj)))
    (when (and entry packet-id)
      (setf (alist-get 'id (car entry)) packet-id)
      (puthash packet-id t meshtastic--my-packet-ids))))

(defun meshtastic--on-ack (obj)
  "Handle an acknowledgement OBJ for a previously sent message."
  (let* ((cmd-id (alist-get 'id obj))
         (entry (gethash cmd-id meshtastic--outgoing)))
    (when entry
      (pcase-let ((`(,_msg ,ttype ,target) entry))
        (meshtastic--set-delivery
         cmd-id
         (cond
          ((not (meshtastic--json-true-p (alist-get 'ok obj))) 'failed)
          ;; A DM is only confirmed when its recipient acknowledges it;
          ;; an implicit ACK from a relay means the mesh heard it.
          ((and (eq ttype 'dm) (not (equal (alist-get 'from obj) target)))
           'relayed)
          (t 'confirmed))
         (let ((reason (alist-get 'reason obj)))
           (unless (equal reason "NONE") reason)))))))

(defun meshtastic--on-error (obj)
  "Handle an error OBJ from the bridge."
  (let ((cmd-id (alist-get 'id obj))
        (text (or (alist-get 'message obj) "unknown error")))
    (cond
     ((and cmd-id (gethash cmd-id meshtastic--outgoing))
      (meshtastic--set-delivery cmd-id 'failed text))
     ((and cmd-id (gethash cmd-id meshtastic--traceroute-entries))
      (meshtastic--traceroute-fail cmd-id text))
     ((and cmd-id (gethash cmd-id meshtastic--request-timers))
      (meshtastic--cancel-request-timer cmd-id)
      (message "Meshtastic: %s" text))
     (t (message "Meshtastic bridge: %s" text)))))

(defun meshtastic--on-traceroute (obj)
  "Handle a traceroute response OBJ from the bridge."
  (let ((cmd-id (alist-get 'id obj))
        (err (alist-get 'error obj)))
    (when cmd-id
      (meshtastic--cancel-request-timer cmd-id)
      (if err
          (meshtastic--traceroute-fail cmd-id (format "No route (%s)" err))
        (meshtastic--traceroute-set-result
         cmd-id
         (alist-get 'dest obj)
         (alist-get 'route obj)
         (alist-get 'routeBack obj)
         (alist-get 'snrTowards obj)
         (alist-get 'snrBack obj))))))

(defun meshtastic--on-position (obj)
  "Handle a position reply OBJ from the bridge."
  (let ((name (meshtastic--node-name (alist-get 'from obj)))
        (lat (alist-get 'lat obj))
        (lon (alist-get 'lon obj))
        (alt (alist-get 'alt obj))
        (err (alist-get 'error obj)))
    (meshtastic--cancel-request-timer (alist-get 'id obj))
    (cond
     (err (message "Meshtastic: no position from %s (%s)" name err))
     ((and lat lon)
      (message "Meshtastic: %s is at %.5f, %.5f%s" name lat lon
               (if alt (format " (%d m)" alt) "")))
     (t (message "Meshtastic: %s has no position fix" name)))))

(defun meshtastic--on-telemetry (obj)
  "Handle a telemetry event OBJ from the bridge."
  (let ((from (alist-get 'from obj)))
    (when (and from (not (string-empty-p from)))
      (puthash from obj meshtastic--telemetry)
      (meshtastic--refresh-node-list))))

(defun meshtastic--on-node-updated (obj)
  "Handle a nodeUpdated event OBJ from the bridge."
  (let ((node-id (alist-get 'nodeId obj)))
    (when (and node-id (not (string-empty-p node-id)))
      (puthash node-id obj meshtastic--nodes)
      (meshtastic--refresh-node-list))))

;;;; Request timeouts

(defun meshtastic--start-request-timer (cmd-id on-timeout)
  "Call ON-TIMEOUT if CMD-ID gets no reply within the request timeout."
  (puthash cmd-id
           (run-at-time meshtastic-request-timeout nil
                        (lambda ()
                          (remhash cmd-id meshtastic--request-timers)
                          (funcall on-timeout)))
           meshtastic--request-timers))

(defun meshtastic--cancel-request-timer (cmd-id)
  "Cancel the timeout timer of CMD-ID, if any."
  (let ((timer (and cmd-id (gethash cmd-id meshtastic--request-timers))))
    (when timer
      (cancel-timer timer)
      (remhash cmd-id meshtastic--request-timers))))

;;;; Delivery tracking

(defun meshtastic--delivery-icon (state &optional msg)
  "Return a propertized delivery icon string for STATE of MSG."
  (let ((reason (and msg (alist-get 'reason msg))))
    (apply #'propertize
           (pcase state
             ('confirmed "✓")
             ('relayed "✓")
             ('failed "✗")
             (_ "·"))
           'face (pcase state
                   ('confirmed 'meshtastic-delivery-confirmed-face)
                   ('relayed 'meshtastic-delivery-relayed-face)
                   ('failed 'meshtastic-delivery-failed-face)
                   (_ 'meshtastic-delivery-pending-face))
           'help-echo (pcase state
                        ('confirmed "Acknowledged")
                        ('relayed "Heard by the mesh, not confirmed by the recipient")
                        ('failed (if reason
                                     (format "Delivery failed: %s" reason)
                                   "Delivery failed"))
                        (_ "Waiting for acknowledgement"))
           (meshtastic--msg-props msg))))

(defun meshtastic--set-delivery (cmd-id state &optional reason)
  "Record delivery STATE and REASON for CMD-ID and update its icon."
  (let ((entry (gethash cmd-id meshtastic--outgoing)))
    (when entry
      (pcase-let ((`(,msg ,ttype ,target) entry))
        (remhash cmd-id meshtastic--outgoing)
        (setf (alist-get 'delivery msg) state
              (alist-get 'reason msg) reason)
        (let ((buf (meshtastic--chat-buffer ttype target)))
          (when buf
            (if (meshtastic--reaction-p msg)
                (when (eq state 'failed)
                  (meshtastic--remove-reaction buf msg)
                  (meshtastic--insert-msg
                   buf nil nil
                   (format "Reaction %s failed%s" (alist-get 'text msg)
                           (if reason (format " (%s)" reason) ""))
                   nil t))
              (meshtastic--update-delivery-icon buf cmd-id msg))))))))

(defun meshtastic--update-delivery-icon (buffer cmd-id msg)
  "Replace the delivery icon for CMD-ID in BUFFER with the state of MSG."
  (with-current-buffer buffer
    (let ((entry (assoc cmd-id meshtastic--delivery-markers)))
      (when entry
        (let ((marker (cdr entry))
              (inhibit-read-only t))
          (when (marker-buffer marker)
            (save-excursion
              (goto-char marker)
              (delete-char 1)
              (insert (meshtastic--delivery-icon
                       (alist-get 'delivery msg) msg))))
          (setq meshtastic--delivery-markers
                (delq entry meshtastic--delivery-markers)))))))

(defun meshtastic--fail-all-outgoing (reason)
  "Mark every unconfirmed outgoing message as failed with REASON."
  (let ((ids nil))
    (maphash (lambda (cmd-id _entry) (push cmd-id ids)) meshtastic--outgoing)
    (dolist (cmd-id ids)
      (meshtastic--set-delivery cmd-id 'failed reason))))

;;;; Sending

(defun meshtastic--split-message (text max-bytes)
  "Split TEXT into parts of at most MAX-BYTES bytes in UTF-8.
Parts are broken at whitespace when possible."
  (let ((parts nil)
        (rest text))
    (while (> (string-bytes rest) max-bytes)
      (let ((end 0)
            (bytes 0))
        ;; Longest prefix that fits.
        (while (and (< end (length rest))
                    (<= (+ bytes (string-bytes (string (aref rest end))))
                        max-bytes))
          (cl-incf bytes (string-bytes (string (aref rest end))))
          (cl-incf end))
        (when (zerop end)
          (setq end 1))
        ;; Prefer to break at the last whitespace in the second half.
        (let ((space (cl-position-if (lambda (c) (memq c '(?\s ?\t ?\n)))
                                     rest :end end :from-end t)))
          (when (and space (> space (/ end 2)))
            (setq end space)))
        (push (string-trim-right (substring rest 0 end)) parts)
        (setq rest (string-trim-left (substring rest end)))))
    (unless (string-empty-p rest)
      (push rest parts))
    (nreverse parts)))

(defun meshtastic--send-message (ttype target text &optional reply-id emoji)
  "Send TEXT to TTYPE and TARGET and show it in the chat buffer.
REPLY-ID is the packet id of the message being answered.  When EMOJI
is non-nil, TEXT is sent as a reaction to REPLY-ID.  Return the
message alist."
  (let* ((cmd-id (meshtastic--cmd-id))
         (dm (eq ttype 'dm))
         (msg (list (cons 'id nil)
                    (cons 'cmdId cmd-id)
                    (cons 'from meshtastic--my-node-id)
                    (cons 'to (if dm target "^all"))
                    (cons 'channel (if dm 0 target))
                    (cons 'text text)
                    (cons 'rxTime (float-time))
                    (cons 'replyId reply-id)
                    (cons 'emoji (and emoji 1))
                    (cons 'delivery 'pending)
                    (cons 'reason nil)))
         (cmd `((action . "send")
                (id . ,cmd-id)
                (text . ,text)
                ,(if dm `(dest . ,target) `(channel . ,target)))))
    (when reply-id (push `(replyId . ,reply-id) cmd))
    (when emoji (push '(emoji . t) cmd))
    (meshtastic--ring-push ttype target msg)
    (puthash cmd-id (list msg ttype target) meshtastic--outgoing)
    (meshtastic--send-cmd cmd)
    (let ((buf (meshtastic--chat-buffer ttype target)))
      (when buf
        (meshtastic--render-messages buf (list msg))))
    msg))

;;;; Chat mode

(defvar meshtastic-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET")     #'meshtastic-send-input)
    (define-key map (kbd "M-p")     #'meshtastic-previous-input)
    (define-key map (kbd "M-n")     #'meshtastic-next-input)
    (define-key map (kbd "C-c C-r") #'meshtastic-reply)
    (define-key map (kbd "C-c C-k") #'meshtastic-cancel-reply)
    (define-key map (kbd "C-g")     #'meshtastic-keyboard-quit)
    (define-key map (kbd "C-c C-e") #'meshtastic-react)
    (define-key map (kbd "C-c C-s") #'meshtastic-resend)
    (define-key map (kbd "C-c C-d") #'meshtastic-dm-at-point)
    (define-key map (kbd "C-c C-i") #'meshtastic-message-info)
    (define-key map (kbd "C-c C-l") #'meshtastic-refresh-chat)
    map)
  "Keymap for `meshtastic-mode'.")

(define-derived-mode meshtastic-mode fundamental-mode "MeshChat"
  "Major mode for Meshtastic chat buffers.
Provides an input prompt with message history above.

\\{meshtastic-mode-map}"
  :group 'meshtastic
  (setq-local meshtastic--prompt-start (make-marker))
  (setq-local meshtastic--prompt-end (make-marker))
  (setq-local meshtastic--input-ring (make-ring 64))
  (setq-local meshtastic--input-ring-index 0)
  (setq-local meshtastic--seen-ids (make-hash-table :test 'equal))
  (setq-local meshtastic--delivery-markers nil)
  (setq-local meshtastic--reactions (make-hash-table :test 'equal))
  (setq mode-line-process
        '(" " (:eval (meshtastic--mode-line-status))))
  (add-hook 'post-command-hook #'force-mode-line-update nil t)
  (add-hook 'window-buffer-change-functions
            #'meshtastic--on-window-display nil t))

(defun meshtastic--input-byte-length ()
  "Return the byte length of the text typed after the prompt."
  (if (and meshtastic--prompt-end (marker-position meshtastic--prompt-end))
      (string-bytes (buffer-substring-no-properties
                     meshtastic--prompt-end (point-max)))
    0))

(defun meshtastic--mode-line-status ()
  "Return the mode-line status string with connection and input size."
  (let ((conn (if meshtastic--connected "[on]" "[off]"))
        (len (meshtastic--input-byte-length))
        (max-total (* meshtastic-max-message-bytes
                      meshtastic-max-message-parts)))
    (cond
     ((zerop len) conn)
     ((> len max-total)
      (format "%s %s" conn (propertize (format "[%d/%d B]" len max-total)
                                       'face 'error)))
     ((> len meshtastic-max-message-bytes)
      (format "%s %s" conn
              (propertize (format "[%d B, %d parts]" len
                                  (length (meshtastic--split-message
                                           (buffer-substring-no-properties
                                            meshtastic--prompt-end (point-max))
                                           meshtastic-max-message-bytes)))
                          'face 'warning)))
     (t (format "%s [%d B]" conn len)))))

;;;; Message rendering

(defun meshtastic--insert-at-prompt (buffer fn)
  "In BUFFER, call FN at the prompt insertion point.
Preserves cursor position when the user is at the end of the buffer."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((inhibit-read-only t)
            (at-end (>= (point) meshtastic--prompt-end)))
        (save-excursion
          (set-marker-insertion-type meshtastic--prompt-start t)
          (set-marker-insertion-type meshtastic--prompt-end t)
          (goto-char meshtastic--prompt-start)
          (funcall fn)
          (set-marker-insertion-type meshtastic--prompt-start nil)
          (set-marker-insertion-type meshtastic--prompt-end nil))
        (when at-end
          (goto-char meshtastic--prompt-end))))))

(defun meshtastic--msg-props (msg)
  "Return the text properties shared by every character of MSG."
  (append '(read-only t rear-nonsticky t front-sticky t)
          (when msg
            (list 'meshtastic-msg msg
                  'meshtastic-sender (meshtastic--node-name
                                      (alist-get 'from msg))))))

(defun meshtastic--msg-header (ts sender selfp &optional reply-name)
  "Return the timestamp, nick and reply indicator of a message line.
TS is a unix timestamp, SENDER the display name, SELFP non-nil for
the local node and REPLY-NAME the sender of the answered message."
  (concat
   (propertize (format "[%s] " (if ts (meshtastic--format-time ts) "--:--"))
               'face 'meshtastic-timestamp-face)
   (propertize (format "<%s> " sender)
               'face (if selfp
                         'meshtastic-nick-self-face
                       'meshtastic-nick-other-face))
   (when reply-name
     (propertize (format "↩ %s: " reply-name)
                 'face 'meshtastic-system-face))))

(defun meshtastic--insert-msg (buffer ts sender text
                                      &optional selfp sysp msg highlight
                                      reply-name)
  "Insert a chat line into BUFFER.
TS is a unix timestamp, SENDER the display name, TEXT the message body.
SELFP non-nil marks the message as from the local node.
SYSP non-nil renders a system notification line instead.
MSG is the message alist, stored for reply, reaction and info commands.
HIGHLIGHT, when `reply' or `mention' and `meshtastic-highlight' is
non-nil, renders the line with `meshtastic-highlight-face'.
REPLY-NAME shows a reply indicator with the answered sender."
  (meshtastic--insert-at-prompt
   buffer
   (lambda ()
     (let ((line (if sysp
                     (propertize (format "*** %s\n" text)
                                 'face 'meshtastic-system-face)
                   (concat (meshtastic--msg-header ts sender selfp reply-name)
                           text "\n"))))
       (when (and meshtastic-highlight (memq highlight '(reply mention)))
         (add-face-text-property 0 (length line)
                                 'meshtastic-highlight-face t line))
       (add-text-properties 0 (length line) (meshtastic--msg-props msg) line)
       (insert line)))))

(defun meshtastic--insert-sent-msg (buffer msg reply-name)
  "Insert the outgoing message MSG with its delivery icon into BUFFER.
REPLY-NAME shows a reply indicator with the answered sender."
  (meshtastic--insert-at-prompt
   buffer
   (lambda ()
     (let ((props (meshtastic--msg-props msg))
           (state (alist-get 'delivery msg)))
       (insert (apply #'propertize
                      (concat (meshtastic--msg-header
                               (alist-get 'rxTime msg)
                               (meshtastic--node-name (alist-get 'from msg))
                               t reply-name)
                              (alist-get 'text msg) " ")
                      props))
       (let ((icon-pos (point)))
         (insert (meshtastic--delivery-icon state msg))
         (insert (apply #'propertize "\n" props))
         (when (eq state 'pending)
           (push (cons (alist-get 'cmdId msg) (copy-marker icon-pos))
                 meshtastic--delivery-markers)))))))

(defun meshtastic--msg-key (msg)
  "Return the deduplication key of MSG."
  (or (alist-get 'cmdId msg) (alist-get 'id msg)))

(defun meshtastic--find-msg-pos (packet-id)
  "Return the buffer position of the message with PACKET-ID, or nil."
  (when packet-id
    (let ((pos (point-min))
          (limit (marker-position meshtastic--prompt-start))
          (found nil))
      (while (and (not found) pos (< pos limit))
        (let ((msg (get-text-property pos 'meshtastic-msg)))
          (if (and msg (equal (alist-get 'id msg) packet-id))
              (setq found pos)
            (setq pos (next-single-property-change
                       pos 'meshtastic-msg nil limit)))))
      found)))

(defun meshtastic--reply-sender (buffer reply-id)
  "Return the sender name of the message REPLY-ID shown in BUFFER."
  (with-current-buffer buffer
    (let ((pos (meshtastic--find-msg-pos reply-id)))
      (and pos (get-text-property pos 'meshtastic-sender)))))

(defun meshtastic--render-reaction-line (buffer packet-id)
  "Redraw the reaction line below the message PACKET-ID in BUFFER."
  (with-current-buffer buffer
    (let ((inhibit-read-only t)
          (msg-pos (meshtastic--find-msg-pos packet-id)))
      (when msg-pos
        (save-excursion
          (goto-char (or (next-single-property-change msg-pos 'meshtastic-msg)
                         (point-max)))
          (let ((start (point)))
            (while (get-text-property (point) 'meshtastic-reaction-for)
              (forward-line 1))
            (delete-region start (point))
            (let ((reactions (reverse (gethash packet-id
                                               meshtastic--reactions))))
              (when reactions
                ;; When the anchor is the last message the line goes right
                ;; before the prompt: advance the marker to keep it below.
                (set-marker-insertion-type meshtastic--prompt-start t)
                (insert (propertize
                         (format "  ↳ %s\n"
                                 (mapconcat (lambda (r)
                                              (format "%s %s" (car r) (cdr r)))
                                            reactions ", "))
                         'face 'meshtastic-system-face
                         'read-only t
                         'rear-nonsticky t
                         'front-sticky t
                         'meshtastic-reaction-for packet-id))
                (set-marker-insertion-type meshtastic--prompt-start nil)))))))))

(defun meshtastic--add-reaction (buffer msg)
  "Show the reaction MSG under the message it targets in BUFFER."
  (let ((target (alist-get 'replyId msg))
        (entry (cons (alist-get 'text msg)
                     (meshtastic--node-name (alist-get 'from msg)))))
    (with-current-buffer buffer
      (unless (member entry (gethash target meshtastic--reactions))
        (push entry (gethash target meshtastic--reactions))))
    (meshtastic--render-reaction-line buffer target)))

(defun meshtastic--remove-reaction (buffer msg)
  "Remove the reaction MSG from BUFFER."
  (let ((target (alist-get 'replyId msg))
        (entry (cons (alist-get 'text msg)
                     (meshtastic--node-name (alist-get 'from msg)))))
    (with-current-buffer buffer
      (setf (gethash target meshtastic--reactions)
            (delete entry (gethash target meshtastic--reactions))))
    (meshtastic--render-reaction-line buffer target)))

(defun meshtastic--render-messages (buffer messages)
  "Render MESSAGES into BUFFER, skipping already-seen messages."
  (when (and (buffer-live-p buffer) messages)
    (let ((ttype (buffer-local-value 'meshtastic--target-type buffer))
          (target (buffer-local-value 'meshtastic--target buffer)))
      (dolist (msg (sort (copy-sequence messages)
                         (lambda (a b)
                           (< (or (alist-get 'rxTime a) 0)
                              (or (alist-get 'rxTime b) 0)))))
        (let ((key (meshtastic--msg-key msg)))
          (unless (and key (gethash key (buffer-local-value
                                         'meshtastic--seen-ids buffer)))
            (when key
              (puthash key t (buffer-local-value 'meshtastic--seen-ids buffer)))
            (meshtastic--render-message buffer msg ttype target)))))))

(defun meshtastic--render-message (buffer msg ttype target)
  "Render a single MSG of conversation TTYPE and TARGET into BUFFER."
  (cond
   ((meshtastic--reaction-p msg)
    (unless (eq (alist-get 'delivery msg) 'failed)
      (meshtastic--add-reaction buffer msg)))
   (t
    (let* ((selfp (meshtastic--is-self-p msg))
           (sender (meshtastic--node-name (alist-get 'from msg)))
           (text (or (alist-get 'text msg) ""))
           (reply-name (meshtastic--reply-sender
                        buffer (alist-get 'replyId msg))))
      (if (and selfp (alist-get 'cmdId msg))
          (meshtastic--insert-sent-msg buffer msg reply-name)
        (let ((highlight (unless selfp
                           (meshtastic--highlight-type msg ttype))))
          (meshtastic--insert-msg buffer (alist-get 'rxTime msg) sender text
                                  selfp nil msg highlight reply-name)
          (unless selfp
            (meshtastic--maybe-notify buffer ttype target sender text
                                      highlight))))))))

;;;; Highlight detection (replies and mentions)

(defun meshtastic--my-nicks ()
  "Return the list of names that count as a mention of you."
  (append (seq-filter (lambda (s) (and (stringp s) (not (string-empty-p s))))
                      (list meshtastic--my-long-name
                            meshtastic--my-short-name
                            meshtastic--my-node-id))
          meshtastic-keywords))

(defun meshtastic--word-match-p (word text)
  "Return non-nil if WORD appears in TEXT, case-insensitively.
Uses a whole-word match when WORD starts or ends with a word
constituent, and a plain substring match otherwise."
  (let ((case-fold-search t))
    (if (string-match-p "\\`\\w\\|\\w\\'" word)
        (string-match-p (concat "\\<" (regexp-quote word) "\\>") text)
      (string-match-p (regexp-quote word) text))))

(defun meshtastic--text-mentions-me-p (text)
  "Return non-nil if TEXT mentions you."
  (when (and (stringp text) (not (string-empty-p text)))
    (seq-some (lambda (nick)
                (and (stringp nick) (not (string-empty-p nick))
                     (meshtastic--word-match-p nick text)))
              (meshtastic--my-nicks))))

(defun meshtastic--highlight-type (msg ttype)
  "Return the highlight type of incoming MSG in a TTYPE conversation.
Returns `reply' when MSG answers one of your messages, `mention' when
it mentions you, `dm' for direct messages, otherwise nil."
  (let ((reply-id (alist-get 'replyId msg)))
    (cond
     ((and reply-id (gethash reply-id meshtastic--my-packet-ids)) 'reply)
     ((meshtastic--text-mentions-me-p (alist-get 'text msg)) 'mention)
     ((eq ttype 'dm) 'dm))))

;;;; Prompt

(defun meshtastic--prompt-string ()
  "Return the prompt string for the current chat buffer."
  (let ((base (pcase meshtastic--target-type
                ('channel (format "#%s> " (meshtastic--channel-name
                                           meshtastic--target)))
                ('dm      (format "%s> " (meshtastic--node-name
                                          meshtastic--target)))
                (_        "Meshtastic> "))))
    (if meshtastic--reply-to
        (format "[reply %s] %s" (cdr meshtastic--reply-to) base)
      base)))

(defun meshtastic--insert-prompt ()
  "Insert the prompt at point and update the prompt markers."
  (let ((start (point)))
    (insert (propertize (meshtastic--prompt-string)
                        'face 'meshtastic-prompt-face
                        'read-only t
                        'front-sticky t
                        'rear-nonsticky t))
    (set-marker meshtastic--prompt-start start)
    (set-marker meshtastic--prompt-end (point))))

(defun meshtastic--setup-prompt ()
  "Insert the read-only input prompt at the end of the current buffer."
  (goto-char (point-max))
  (meshtastic--insert-prompt))

(defun meshtastic--refresh-prompt ()
  "Redraw the prompt, preserving the input typed after it."
  (let ((inhibit-read-only t)
        (input (buffer-substring-no-properties
                meshtastic--prompt-end (point-max))))
    (save-excursion
      (delete-region meshtastic--prompt-start (point-max))
      (goto-char meshtastic--prompt-start)
      (meshtastic--insert-prompt)
      (insert input))))

;;;; Input handling

(defun meshtastic-send-input ()
  "Send the text typed after the prompt.
Input longer than `meshtastic-max-message-bytes' is split into
several messages."
  (interactive)
  (if (< (point) meshtastic--prompt-end)
      (goto-char (point-max))
    (let ((input (buffer-substring-no-properties
                  meshtastic--prompt-end (point-max))))
      (when (string-blank-p input)
        (user-error "Empty message"))
      (unless meshtastic--connected
        (user-error "Meshtastic is not connected"))
      (let ((parts (meshtastic--split-message
                    (string-trim input) meshtastic-max-message-bytes)))
        (when (> (length parts) meshtastic-max-message-parts)
          (user-error "Message too long: %d bytes, the maximum is %d"
                      (string-bytes input)
                      (* meshtastic-max-message-bytes
                         meshtastic-max-message-parts)))
        (ring-insert meshtastic--input-ring input)
        (setq meshtastic--input-ring-index 0)
        (let ((inhibit-read-only t))
          (delete-region meshtastic--prompt-end (point-max)))
        (meshtastic--send-parts parts)))))

(defun meshtastic--send-parts (parts)
  "Send PARTS to the target of the current chat buffer.
Only the first part carries the pending reply context."
  (unless meshtastic--target-type
    (user-error "No target set for this buffer"))
  (let ((reply-id (car meshtastic--reply-to)))
    (when meshtastic--reply-to
      (setq meshtastic--reply-to nil)
      (meshtastic--refresh-prompt))
    (dolist (part parts)
      (meshtastic--send-message meshtastic--target-type meshtastic--target
                                part reply-id)
      (setq reply-id nil))))

(defun meshtastic--navigate-input (dir)
  "Move DIR step through the input ring (1 = older, -1 = newer)."
  (when (> (ring-length meshtastic--input-ring) 0)
    (let ((inhibit-read-only t))
      (delete-region meshtastic--prompt-end (point-max))
      (when (= dir -1)
        (setq meshtastic--input-ring-index
              (mod (1- meshtastic--input-ring-index)
                   (ring-length meshtastic--input-ring))))
      (insert (ring-ref meshtastic--input-ring
                        meshtastic--input-ring-index))
      (when (= dir 1)
        (setq meshtastic--input-ring-index
              (mod (1+ meshtastic--input-ring-index)
                   (ring-length meshtastic--input-ring)))))))

(defun meshtastic-previous-input ()
  "Replace the current input with the previous history entry."
  (interactive)
  (meshtastic--navigate-input 1))

(defun meshtastic-next-input ()
  "Replace the current input with the next history entry."
  (interactive)
  (meshtastic--navigate-input -1))

;;;; Message commands

(defun meshtastic--msg-at-point ()
  "Return the message alist at point or on the current line, or nil."
  (or (get-text-property (point) 'meshtastic-msg)
      (let ((pos (line-beginning-position))
            (end (line-end-position))
            (found nil))
        (while (and (not found) (< pos end))
          (setq found (get-text-property pos 'meshtastic-msg)
                pos (next-single-property-change pos 'meshtastic-msg nil end)))
        found)))

(defun meshtastic--packet-id-at-point ()
  "Return the packet id and message at point, or signal a user error."
  (let ((msg (meshtastic--msg-at-point)))
    (unless msg
      (user-error "No message at point"))
    (unless (alist-get 'id msg)
      (user-error "This message has not been sent yet"))
    msg))

(defun meshtastic-reply ()
  "Reply to the message at point.
The next message you send is marked as an answer to it."
  (interactive)
  (let* ((msg (meshtastic--packet-id-at-point))
         (sender (meshtastic--node-name (alist-get 'from msg))))
    (setq meshtastic--reply-to (cons (alist-get 'id msg) sender))
    (meshtastic--refresh-prompt)
    (goto-char (point-max))
    (message "Replying to %s (%s to cancel)" sender
             (substitute-command-keys "\\[meshtastic-cancel-reply]"))))

(defun meshtastic-cancel-reply ()
  "Cancel the pending reply."
  (interactive)
  (setq meshtastic--reply-to nil)
  (meshtastic--refresh-prompt)
  (message "Reply cancelled"))

(defun meshtastic-keyboard-quit ()
  "Cancel a pending reply, or run `keyboard-quit'."
  (interactive)
  (if meshtastic--reply-to
      (meshtastic-cancel-reply)
    (keyboard-quit)))

(declare-function emojify-completing-read "emojify" (&optional prompt))

(defun meshtastic-react ()
  "React with an emoji to the message at point.
Uses `emojify-completing-read' when available."
  (interactive)
  (unless meshtastic--connected
    (user-error "Meshtastic is not connected"))
  (let* ((msg (meshtastic--packet-id-at-point))
         (emoji (if (fboundp 'emojify-completing-read)
                    (emojify-completing-read "Reaction: ")
                  (read-string "Emoji: "))))
    (when (string-empty-p (string-trim (or emoji "")))
      (user-error "No emoji given"))
    (meshtastic--send-message meshtastic--target-type meshtastic--target
                              (string-trim emoji) (alist-get 'id msg) t)))

(defun meshtastic-resend ()
  "Send the text of the message at point again."
  (interactive)
  (let ((msg (meshtastic--msg-at-point)))
    (unless msg
      (user-error "No message at point"))
    (unless meshtastic--connected
      (user-error "Meshtastic is not connected"))
    (meshtastic--send-message meshtastic--target-type meshtastic--target
                              (alist-get 'text msg))
    (goto-char (point-max))))

(defun meshtastic-dm-at-point ()
  "Open a DM chat with the sender of the message at point."
  (interactive)
  (let ((msg (meshtastic--msg-at-point)))
    (unless msg
      (user-error "No message at point"))
    (when (meshtastic--is-self-p msg)
      (user-error "That message was sent by you"))
    (meshtastic-open-dm (alist-get 'from msg))))

;;;; Message info

(defun meshtastic--relay-name (relay)
  "Describe RELAY, the last byte of the relaying node number."
  (let ((names nil))
    (maphash (lambda (id node)
               (let ((num (alist-get 'nodeNum node)))
                 (when (and (numberp num) (= (logand num 255) relay))
                   (push (meshtastic--node-name id) names))))
             meshtastic--nodes)
    (if names
        (format "0x%02x (%s)" relay (string-join names " or "))
      (format "0x%02x" relay))))

(defun meshtastic--msg-info-lines (msg)
  "Return a list of (LABEL . VALUE) pairs describing MSG.
Pairs with a nil VALUE are dropped by the caller."
  (let* ((from (alist-get 'from msg))
         (to (alist-get 'to msg))
         (broadcast (meshtastic--broadcast-p to))
         (channel (alist-get 'channel msg))
         (hop-start (alist-get 'hopStart msg))
         (hop-limit (alist-get 'hopLimit msg))
         (snr (alist-get 'rxSnr msg))
         (rssi (alist-get 'rxRssi msg))
         (relay (alist-get 'relayNode msg))
         (ts (alist-get 'rxTime msg))
         (state (alist-get 'delivery msg)))
    (list
     (cons "From" (and from (format "%s (%s)" (meshtastic--node-name from) from)))
     (cons "To" (if broadcast
                    "broadcast"
                  (format "%s (%s)" (meshtastic--node-name to) to)))
     (cons "Channel" (if (and broadcast (numberp channel))
                         (format "%s (%d)" (meshtastic--channel-name channel)
                                 channel)
                       "direct message"))
     (cons "Time" (and (numberp ts)
                       (format-time-string "%Y-%m-%d %H:%M:%S"
                                           (seconds-to-time ts))))
     (cons "Delivery" (and state
                           (concat (symbol-name state)
                                   (let ((r (alist-get 'reason msg)))
                                     (if r (format " (%s)" r) "")))))
     (cons "Hops" (and (numberp hop-start) (numberp hop-limit)
                       (format "%d (start %d, remaining %d)"
                               (max 0 (- hop-start hop-limit))
                               hop-start hop-limit)))
     (cons "SNR" (and (numberp snr) (format "%.2f dB" snr)))
     (cons "RSSI" (and (numberp rssi) (format "%d dBm" rssi)))
     (cons "Relay node" (and (numberp relay) (> relay 0)
                             (meshtastic--relay-name relay)))
     (cons "Via MQTT" (and (assq 'viaMqtt msg)
                           (if (meshtastic--json-true-p (alist-get 'viaMqtt msg))
                               "yes" "no")))
     (cons "Packet ID" (let ((id (alist-get 'id msg)))
                         (and id (format "%s" id))))
     (cons "Reply to" (let ((r (alist-get 'replyId msg)))
                        (and (numberp r) (/= r 0) (number-to-string r)))))))

(defun meshtastic-message-info ()
  "Show details about the message at point.
Displays sender, recipient, delivery state, hop count and radio metrics."
  (interactive)
  (let ((msg (meshtastic--msg-at-point)))
    (unless msg
      (user-error "No message at point"))
    (let ((buf (get-buffer-create "*Meshtastic: Message Info*"))
          (lines (seq-filter #'cdr (meshtastic--msg-info-lines msg)))
          (text (alist-get 'text msg)))
      (with-current-buffer buf
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert (propertize "Message info\n" 'face 'bold))
          (insert (make-string 24 ?═) "\n\n")
          (dolist (pair lines)
            (insert (propertize (format "%-12s" (concat (car pair) ":"))
                                'face 'meshtastic-system-face))
            (insert (format "%s\n" (cdr pair))))
          (when (and text (not (string-empty-p text)))
            (insert "\n" (propertize "Text\n" 'face 'bold)
                    (make-string 24 ?─) "\n" text "\n")))
        (goto-char (point-min))
        (special-mode))
      (display-buffer buf))))

;;;; Buffer management

(defun meshtastic--buffer-name (ttype target)
  "Return the buffer name for chat type TTYPE and TARGET."
  (pcase ttype
    ('channel (format "*Meshtastic: #%s*" (meshtastic--channel-name target)))
    ('dm      (format "*Meshtastic: DM %s*" (meshtastic--node-name target)))))

(defun meshtastic--chat-buffer (ttype target)
  "Return the live chat buffer for TTYPE and TARGET, or nil."
  (let ((buf (cdr (assoc (cons ttype target) meshtastic--chat-buffers))))
    (and (buffer-live-p buf) buf)))

(defun meshtastic--get-or-create-buffer (ttype target)
  "Return an existing or new chat buffer for TTYPE and TARGET."
  (or (meshtastic--chat-buffer ttype target)
      (let ((buf (generate-new-buffer (meshtastic--buffer-name ttype target))))
        (with-current-buffer buf
          (meshtastic-mode)
          (setq meshtastic--target target
                meshtastic--target-type ttype)
          (meshtastic--setup-prompt))
        (setq meshtastic--chat-buffers
              (cons (cons (cons ttype target) buf)
                    (seq-filter (lambda (e) (buffer-live-p (cdr e)))
                                meshtastic--chat-buffers)))
        buf)))

(defun meshtastic-refresh-chat ()
  "Redraw the current chat buffer from the buffered messages."
  (interactive)
  (unless meshtastic--target
    (user-error "Not a chat buffer"))
  (let ((inhibit-read-only t))
    (delete-region (point-min) meshtastic--prompt-start))
  (clrhash meshtastic--seen-ids)
  (clrhash meshtastic--reactions)
  (setq meshtastic--delivery-markers nil)
  (meshtastic--render-messages
   (current-buffer)
   (meshtastic--ring-messages meshtastic--target-type meshtastic--target))
  (message "Meshtastic: refreshed"))

;;;; Notifications

(defun meshtastic--maybe-notify (buffer ttype target sender text highlight)
  "Maybe notify about a message from SENDER with TEXT.
BUFFER is the chat buffer, or nil when it is not open.  TTYPE and
TARGET identify the conversation, HIGHLIGHT is the highlight type or
nil.  The decision honors `meshtastic-notify'."
  (let ((mode meshtastic-notify))
    (cond
     ((null mode))
     ((eq mode 'highlights)
      (when (and highlight
                 (not (and buffer
                           (eq buffer (window-buffer (selected-window))))))
        (meshtastic--notify sender text ttype target highlight)))
     (t
      (unless (and buffer (get-buffer-window buffer t))
        (meshtastic--notify sender text ttype target
                            (or highlight 'message)))))))

(defun meshtastic--notify (sender text ttype target type)
  "Notify about a message from SENDER with TEXT.
TTYPE and TARGET identify the conversation.  TYPE is one of `reply',
`mention', `dm' or `message' and sets the title prefix and urgency."
  (let ((title (concat (pcase type ('reply "↩ ") ('mention "@ ") (_ ""))
                       (if (eq ttype 'dm)
                           sender
                         (meshtastic--target-name ttype target))))
        (body (truncate-string-to-width
               (format "%s: %s" sender text) 100 nil nil "...")))
    (meshtastic--dispatch-notification
     title body type (memq type '(reply mention dm)))))

(defun meshtastic--dispatch-notification (title body type urgent)
  "Deliver TITLE and BODY using `meshtastic-notify-method'.
TYPE is the highlight type symbol.  URGENT non-nil raises priority."
  (let ((method meshtastic-notify-method))
    (cond
     ((functionp method) (funcall method title body type))
     ((eq method 'minibuffer) (meshtastic--notify-minibuffer title body))
     ((eq method 'both)
      (meshtastic--notify-native title body urgent)
      (meshtastic--notify-minibuffer title body))
     (t (meshtastic--notify-native title body urgent)))))

(defun meshtastic--notify-minibuffer (title body)
  "Show TITLE and BODY in the echo area."
  (message "Meshtastic %s: %s" title body))

(defun meshtastic--notify-native (title body urgent)
  "Show a native OS notification with TITLE and BODY.
URGENT non-nil requests a higher priority where supported.  Falls
back to the echo area when no native mechanism works."
  (condition-case nil
      (cond
       ((eq system-type 'darwin)
        (meshtastic--notify-macos title body))
       ((and (featurep 'dbusbind)
             (fboundp 'notifications-notify))
        (notifications-notify
         :title title :body body
         :app-name "Meshtastic"
         :category "im.received"
         :urgency (if urgent 'critical 'normal)))
       ((executable-find "notify-send")
        (call-process "notify-send" nil 0 nil
                      "-a" "Meshtastic"
                      "-u" (if urgent "critical" "normal")
                      title body))
       (t (meshtastic--notify-minibuffer title body)))
    (error (meshtastic--notify-minibuffer title body))))

(defun meshtastic--applescript-quote (string)
  "Return STRING quoted as an AppleScript string literal."
  (concat "\""
          (replace-regexp-in-string "\\([\"\\]\\)" "\\\\\\1" string)
          "\""))

(defun meshtastic--notify-macos (title body)
  "Show a macOS notification with TITLE and BODY.
Uses `terminal-notifier' when available, otherwise `osascript'."
  (let ((tn (executable-find "terminal-notifier")))
    (if tn
        (call-process tn nil 0 nil
                      "-title" title
                      "-message" body
                      "-group" "meshtastic"
                      "-sender" "org.gnu.Emacs")
      (call-process
       "osascript" nil 0 nil
       "-e" (format "display notification %s with title %s"
                    (meshtastic--applescript-quote body)
                    (meshtastic--applescript-quote title))))))

;;;; Live views

(defun meshtastic--refresh-node-list ()
  "Redraw the node list buffer if it is open."
  (let ((buf (get-buffer "*Meshtastic: Nodes*")))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (meshtastic--populate-node-list)))))

(defun meshtastic--refresh-views ()
  "Redraw the welcome, channel, DM and unread buffers if they are open."
  (let ((welcome (get-buffer "*Meshtastic*"))
        (channels (get-buffer "*Meshtastic: Channels*"))
        (dms (get-buffer "*Meshtastic: Direct Messages*"))
        (unread (get-buffer "*Meshtastic: Unread*")))
    (when (buffer-live-p welcome)
      (meshtastic--render-welcome))
    (when (buffer-live-p channels)
      (with-current-buffer channels (meshtastic--populate-channel-list)))
    (when (buffer-live-p dms)
      (with-current-buffer dms (meshtastic--populate-dm-list)))
    (when (buffer-live-p unread)
      (with-current-buffer unread (meshtastic--populate-unread-list)))))

;;;; Channel list mode

(defvar meshtastic-channel-list-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map (kbd "RET") #'meshtastic-channel-list-open)
    (define-key map (kbd "g")   #'meshtastic-channel-list-refresh)
    (dotimes (i 8)
      (define-key map (kbd (number-to-string i))
                  #'meshtastic-channel-list-open-by-number))
    map)
  "Keymap for `meshtastic-channel-list-mode'.")

(define-derived-mode meshtastic-channel-list-mode tabulated-list-mode
  "MeshChannels"
  "Major mode for listing Meshtastic channels."
  :group 'meshtastic
  (setq tabulated-list-format
        [("ID" 4 t) ("Name" 20 t) ("Role" 12 t) ("Unread" 6 t)])
  (setq tabulated-list-padding 2)
  (tabulated-list-init-header))

(defun meshtastic-channel-list-open-by-number ()
  "Open the channel whose number matches the digit key pressed."
  (interactive)
  (meshtastic-open-channel (- last-command-event ?0)))

(defun meshtastic-channel-list-open ()
  "Open a chat buffer for the channel at point."
  (interactive)
  (let ((id (tabulated-list-get-id)))
    (when id
      (meshtastic-open-channel id))))

(defun meshtastic-channel-list-refresh ()
  "Request an updated channel list from the device."
  (interactive)
  (meshtastic--send-cmd '((action . "channels")))
  (message "Meshtastic: refreshing channels..."))

(defun meshtastic--populate-channel-list ()
  "Fill the channel list buffer from the in-memory channel cache."
  (let ((role-names '((0 . "Disabled") (1 . "Primary") (2 . "Secondary"))))
    (setq tabulated-list-entries
          (mapcar
           (lambda (ch)
             (let* ((idx  (or (alist-get 'index ch) 0))
                    (role (or (alist-get 'role ch) 0))
                    (unread (gethash (cons 'channel idx) meshtastic--unread)))
               (list idx
                     (vector (number-to-string idx)
                             (or (alist-get 'name ch) "")
                             (or (cdr (assq role role-names))
                                 (format "%d" role))
                             (if unread (number-to-string unread) "")))))
           (meshtastic--active-channels)))
    (tabulated-list-print t)))

;;;; Node list mode

(defvar meshtastic-node-list-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map (kbd "RET") #'meshtastic-node-list-open)
    (define-key map (kbd "d")   #'meshtastic-node-list-open)
    (define-key map (kbd "g")   #'meshtastic-node-list-refresh)
    (define-key map (kbd "o")   #'meshtastic-node-list-toggle-online)
    (define-key map (kbd "t")   #'meshtastic-traceroute)
    (define-key map (kbd "p")   #'meshtastic-request-position)
    (define-key map (kbd "P")   #'meshtastic-send-position)
    map)
  "Keymap for `meshtastic-node-list-mode'.")

(define-derived-mode meshtastic-node-list-mode tabulated-list-mode
  "MeshNodes"
  "Major mode for listing Meshtastic mesh nodes sorted by hop count.
A green dot marks online nodes and a key marks nodes with a public
key, which enables end-to-end encrypted direct messages.

\\{meshtastic-node-list-mode-map}"
  :group 'meshtastic
  (setq tabulated-list-format
        [("Hops" 5 meshtastic--sort-by-hops)
         ("Name" 30 t)
         ("Node ID" 14 t)
         ("Last heard" 12 meshtastic--sort-by-last-heard)
         ("Battery" 8 t)])
  (setq tabulated-list-padding 2)
  (setq tabulated-list-sort-key '("Hops"))
  (tabulated-list-init-header))

(defun meshtastic--hops-sort-value (entry)
  "Return the hop count of tabulated ENTRY, unknown hops last."
  (let ((hops (aref (cadr entry) 0)))
    (if (equal hops "?") 99 (string-to-number hops))))

(defun meshtastic--sort-by-hops (a b)
  "Sort tabulated entries A and B by hop count ascending."
  (< (meshtastic--hops-sort-value a) (meshtastic--hops-sort-value b)))

(defun meshtastic--sort-by-last-heard (a b)
  "Sort tabulated entries A and B by last-heard time, most recent first."
  (let ((ta (or (alist-get 'lastHeard (gethash (car a) meshtastic--nodes)) 0))
        (tb (or (alist-get 'lastHeard (gethash (car b) meshtastic--nodes)) 0)))
    (> ta tb)))

(defun meshtastic-node-list-open ()
  "Open a DM chat buffer with the node at point.
Asks for confirmation when the node has no public key, because the
message would then be encrypted with the shared channel key."
  (interactive)
  (let ((node-id (meshtastic--node-id-at-point)))
    (unless node-id
      (user-error "No node at point"))
    (when (or (meshtastic--node-has-pkc-p node-id)
              (y-or-n-p
               (format "%s has no public key, the DM will use the channel key.  Open anyway? "
                       (meshtastic--node-name node-id))))
      (meshtastic-open-dm node-id))))

(defun meshtastic-node-list-refresh ()
  "Request an updated node list from the device."
  (interactive)
  (meshtastic--send-cmd '((action . "nodes")))
  (message "Meshtastic: refreshing nodes..."))

(defun meshtastic-node-list-toggle-online ()
  "Toggle between showing all nodes and only online nodes.
A node is online when it was heard within `meshtastic-online-threshold'."
  (interactive)
  (setq meshtastic--node-list-online-only
        (not meshtastic--node-list-online-only))
  (meshtastic--populate-node-list)
  (message "Meshtastic: showing %s nodes"
           (if meshtastic--node-list-online-only "only online" "all")))

(defun meshtastic--populate-node-list ()
  "Fill the node list buffer from the in-memory node cache."
  (let ((entries nil))
    (maphash
     (lambda (node-id node)
       (let* ((hops (alist-get 'hopsAway node))
              (last-heard (alist-get 'lastHeard node))
              (online (meshtastic--node-online-p last-heard))
              (tel (gethash node-id meshtastic--telemetry))
              (battery (and tel (alist-get 'batteryLevel tel))))
         (when (or online (not meshtastic--node-list-online-only))
           (push (list node-id
                       (vector (if (numberp hops) (number-to-string hops) "?")
                               (concat (if online "🟢" "⚫")
                                       (if (meshtastic--node-has-pkc-p node-id)
                                           "🔑" "  ")
                                       " "
                                       (meshtastic--node-name node-id))
                               node-id
                               (meshtastic--format-last-heard last-heard)
                               (if (numberp battery)
                                   (format "%d%%" battery)
                                 "-")))
                 entries))))
     meshtastic--nodes)
    (setq tabulated-list-entries entries)
    (setq mode-name (if meshtastic--node-list-online-only
                        "MeshNodes[online]"
                      "MeshNodes"))
    (tabulated-list-print t)))

;;;; Direct message list mode

(defvar meshtastic-dm-list-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map (kbd "RET") #'meshtastic-dm-list-open)
    (define-key map (kbd "g")   #'meshtastic-dm-list-refresh)
    map)
  "Keymap for `meshtastic-dm-list-mode'.")

(define-derived-mode meshtastic-dm-list-mode tabulated-list-mode "MeshDMs"
  "Major mode for listing Meshtastic direct message conversations."
  :group 'meshtastic
  (setq tabulated-list-format
        [("Time" 6 nil)
         ("Name" 22 t)
         ("Node ID" 12 t)
         ("Unread" 6 t)
         ("Last message" 40 nil)])
  (setq tabulated-list-padding 2)
  (tabulated-list-init-header))

(defun meshtastic-dm-list-open ()
  "Open the DM conversation at point."
  (interactive)
  (let ((id (tabulated-list-get-id)))
    (when id
      (meshtastic-open-dm id))))

(defun meshtastic-dm-list-refresh ()
  "Redraw the DM conversation list."
  (interactive)
  (meshtastic--populate-dm-list))

(defun meshtastic--dm-targets ()
  "Return the node IDs of every DM conversation in memory or open."
  (let ((ids nil))
    (maphash (lambda (key _ring)
               (when (eq (car key) 'dm)
                 (cl-pushnew (cdr key) ids :test #'equal)))
             meshtastic--message-rings)
    (dolist (entry meshtastic--chat-buffers)
      (when (and (eq (caar entry) 'dm) (buffer-live-p (cdr entry)))
        (cl-pushnew (cdar entry) ids :test #'equal)))
    ids))

(defun meshtastic--populate-dm-list ()
  "Fill the DM list buffer, most recent conversation first."
  (let ((rows nil))
    (dolist (node-id (meshtastic--dm-targets))
      (let* ((last (meshtastic--last-text-message 'dm node-id))
             (ts (or (and last (alist-get 'rxTime last)) 0))
             (unread (gethash (cons 'dm node-id) meshtastic--unread)))
        (push (cons ts
                    (list node-id
                          (vector (if (> ts 0) (meshtastic--format-time ts) "")
                                  (meshtastic--node-name node-id)
                                  node-id
                                  (if unread (number-to-string unread) "")
                                  (truncate-string-to-width
                                   (or (and last (alist-get 'text last)) "")
                                   40 nil nil "..."))))
              rows)))
    (setq tabulated-list-entries
          (mapcar #'cdr (sort rows (lambda (a b) (> (car a) (car b))))))
    (tabulated-list-print t)))

;;;; Unread list mode

(defvar meshtastic-unread-list-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map (kbd "RET") #'meshtastic-unread-list-open)
    (define-key map (kbd "g")   #'meshtastic-unread-list-refresh)
    map)
  "Keymap for `meshtastic-unread-list-mode'.")

(define-derived-mode meshtastic-unread-list-mode tabulated-list-mode
  "MeshUnread"
  "Major mode for listing conversations with unread messages."
  :group 'meshtastic
  (setq tabulated-list-format
        [("Unread" 7 meshtastic--sort-by-unread)
         ("Conversation" 25 t)
         ("Last message" 50 nil)])
  (setq tabulated-list-padding 2)
  (setq tabulated-list-sort-key '("Unread" . t))
  (tabulated-list-init-header))

(defun meshtastic--sort-by-unread (a b)
  "Sort tabulated entries A and B by unread count."
  (< (string-to-number (aref (cadr a) 0))
     (string-to-number (aref (cadr b) 0))))

(defun meshtastic-unread-list-open ()
  "Open the conversation at point."
  (interactive)
  (pcase (tabulated-list-get-id)
    (`(channel . ,index) (meshtastic-open-channel index))
    (`(dm . ,node-id) (meshtastic-open-dm node-id))))

(defun meshtastic-unread-list-refresh ()
  "Redraw the unread conversation list."
  (interactive)
  (meshtastic--populate-unread-list))

(defun meshtastic--populate-unread-list ()
  "Fill the unread list buffer from the unread counters."
  (let ((entries nil))
    (maphash
     (lambda (key count)
       (let ((last (meshtastic--last-text-message (car key) (cdr key))))
         (push (list key
                     (vector (number-to-string count)
                             (meshtastic--target-name (car key) (cdr key))
                             (truncate-string-to-width
                              (if last
                                  (format "%s: %s"
                                          (meshtastic--node-name
                                           (alist-get 'from last))
                                          (alist-get 'text last))
                                "")
                              50 nil nil "...")))
               entries)))
     meshtastic--unread)
    (setq tabulated-list-entries entries)
    (tabulated-list-print t)))

;;;; Node actions

(defun meshtastic--node-id-at-point ()
  "Return the node ID of the node or DM list entry at point."
  (and (derived-mode-p 'meshtastic-node-list-mode 'meshtastic-dm-list-mode)
       (tabulated-list-get-id)))

(defun meshtastic--node-id-context ()
  "Return a contextual node ID from the current buffer.
Tries the node list entry at point first, then the DM target."
  (or (meshtastic--node-id-at-point)
      (and (eq meshtastic--target-type 'dm) meshtastic--target)))

(defun meshtastic--read-node-id ()
  "Return the contextual node ID, or read one from the minibuffer."
  (or (meshtastic--node-id-context)
      (let* ((choices (let ((acc nil))
                        (maphash (lambda (id _node)
                                   (push (cons (format "%s (%s)"
                                                       (meshtastic--node-name id)
                                                       id)
                                               id)
                                         acc))
                                 meshtastic--nodes)
                        acc))
             (choice (completing-read "Node: " choices)))
        (or (cdr (assoc choice choices)) choice))))

;;;###autoload
(defun meshtastic-traceroute (node-id)
  "Send a traceroute to NODE-ID via the bridge.
When called from the node list, uses the node at point.
When called from a DM buffer, uses the DM target.
Otherwise prompts for a node."
  (interactive (list (meshtastic--read-node-id)))
  (meshtastic--send-traceroute node-id))

(defun meshtastic--send-traceroute (node-id)
  "Send a traceroute request to NODE-ID and show the traceroute buffer."
  (unless meshtastic--connected
    (user-error "Not connected"))
  (let ((cmd-id (meshtastic--cmd-id)))
    (meshtastic--traceroute-append cmd-id node-id)
    (meshtastic--start-request-timer
     cmd-id (lambda () (meshtastic--traceroute-fail cmd-id "No response (timeout)")))
    (meshtastic--send-cmd
     `((action   . "traceroute")
       (id       . ,cmd-id)
       (dest     . ,node-id)
       (hopLimit . 7)))
    (display-buffer (meshtastic--traceroute-buffer))
    (message "Meshtastic: traceroute to %s..."
             (meshtastic--node-name node-id))))

;;;###autoload
(defun meshtastic-request-position (node-id)
  "Ask NODE-ID for its current position.
When called from the node list, uses the node at point.
When called from a DM buffer, uses the DM target.
Otherwise prompts for a node."
  (interactive (list (meshtastic--read-node-id)))
  (unless meshtastic--connected
    (user-error "Not connected"))
  (let ((cmd-id (meshtastic--cmd-id))
        (name (meshtastic--node-name node-id)))
    (meshtastic--start-request-timer
     cmd-id (lambda ()
              (message "Meshtastic: no position reply from %s" name)))
    (meshtastic--send-cmd `((action . "requestposition")
                            (id     . ,cmd-id)
                            (dest   . ,node-id)))
    (message "Meshtastic: requesting position from %s..." name)))

;;;; Traceroute buffer

(defvar meshtastic-traceroute-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "q") #'quit-window)
    map)
  "Keymap for `meshtastic-traceroute-mode'.")

(define-derived-mode meshtastic-traceroute-mode special-mode "MeshTrace"
  "Major mode for the Meshtastic traceroute log."
  :group 'meshtastic
  (buffer-disable-undo)
  (setq truncate-lines t))

(defun meshtastic--traceroute-buffer ()
  "Return the traceroute log buffer, creating it if needed."
  (let ((buf (get-buffer-create "*Meshtastic: Traceroute*")))
    (with-current-buffer buf
      (unless (derived-mode-p 'meshtastic-traceroute-mode)
        (meshtastic-traceroute-mode)))
    buf))

(defun meshtastic--format-route-segment (nodes snrs)
  "Return \" → node (snr)\" string for each element in NODES paired with SNRS."
  (mapconcat
   #'identity
   (cl-mapcar
    (lambda (node snr)
      (format " → %s%s"
              (meshtastic--node-name node)
              (if snr (format " (%.1fdB)" snr) "")))
    nodes
    (append snrs (make-list (max 0 (- (length nodes) (length snrs))) nil)))
   ""))

(defun meshtastic--traceroute-format-result (dest-id route route-back snr-fwd snr-back)
  "Return formatted multi-line status for a completed traceroute to DEST-ID.
ROUTE and ROUTE-BACK are lists of intermediate node ID strings.
SNR-FWD and SNR-BACK are lists of SNR floats (dB) for each hop."
  (let* ((local (or meshtastic--my-long-name meshtastic--my-node-id "Local"))
         (dest  (meshtastic--node-name dest-id))
         (fwd   (concat local
                        (meshtastic--format-route-segment route snr-fwd)
                        " → " dest))
         (bck   (concat dest
                        (meshtastic--format-route-segment route-back snr-back)
                        " → " local)))
    (concat
     (propertize (format "  ✓ → %s\n" fwd) 'face 'meshtastic-delivery-confirmed-face)
     (propertize (format "  ← %s\n" bck) 'face 'meshtastic-system-face))))

(defun meshtastic--traceroute-append (cmd-id dest-id)
  "Append a pending entry for CMD-ID targeting DEST-ID to the traceroute buffer."
  (let ((buf (meshtastic--traceroute-buffer)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (goto-char (point-max))
        (insert (format "[%s] → %s (%s)\n"
                        (format-time-string "%H:%M:%S")
                        (meshtastic--node-name dest-id)
                        dest-id))
        (let ((s-start (copy-marker (point))))
          (insert "  ⧖ Pending...\n")
          (let ((s-end (copy-marker (point))))
            (insert "\n")
            (puthash cmd-id (cons s-start s-end)
                     meshtastic--traceroute-entries)))))))

(defun meshtastic--traceroute-replace (cmd-id text)
  "Replace the pending status line of CMD-ID with TEXT."
  (let ((entry (gethash cmd-id meshtastic--traceroute-entries)))
    (when entry
      (remhash cmd-id meshtastic--traceroute-entries)
      (let ((s-start (car entry))
            (s-end (cdr entry)))
        (when (and (buffer-live-p (marker-buffer s-start))
                   (marker-buffer s-end))
          (with-current-buffer (marker-buffer s-start)
            (let ((inhibit-read-only t))
              (delete-region s-start s-end)
              (save-excursion
                (goto-char s-start)
                (insert text)))))))))

(defun meshtastic--traceroute-set-result (cmd-id dest-id route route-back snr-fwd snr-back)
  "Replace the pending status for CMD-ID with route result data.
DEST-ID is the destination node ID.  ROUTE and ROUTE-BACK are lists of
intermediate node ID strings.  SNR-FWD and SNR-BACK are SNR floats in dB."
  (meshtastic--traceroute-replace
   cmd-id
   (meshtastic--traceroute-format-result
    dest-id route route-back snr-fwd snr-back)))

(defun meshtastic--traceroute-fail (cmd-id reason)
  "Replace the pending status for CMD-ID with a failure showing REASON."
  (meshtastic--cancel-request-timer cmd-id)
  (meshtastic--traceroute-replace
   cmd-id
   (propertize (format "  ✗ %s\n" reason)
               'face 'meshtastic-delivery-failed-face)))

;;;; Position

(defun meshtastic--calendar-to-float (val)
  "Convert calendar coordinate VAL to a float.
Handles both plain numbers and (degrees minutes direction) lists."
  (cond
   ((numberp val) (float val))
   ((and (listp val) (>= (length val) 2))
    (let* ((deg (float (nth 0 val)))
           (min (float (nth 1 val)))
           (dir (nth 2 val))
           (abs (+ deg (/ min 60.0))))
      (if (memq dir '(south west)) (- abs) abs)))
   (t nil)))

(defun meshtastic--get-emacs-position ()
  "Return (lat lon) from Emacs calendar variables, or nil if not set."
  (when (and (boundp 'calendar-latitude)
             (boundp 'calendar-longitude)
             calendar-latitude
             calendar-longitude)
    (let ((lat (meshtastic--calendar-to-float calendar-latitude))
          (lon (meshtastic--calendar-to-float calendar-longitude)))
      (when (and lat lon)
        (list lat lon)))))

;;;###autoload
(defun meshtastic-send-position (node-id)
  "Send GPS position to NODE-ID.
Uses `calendar-latitude' and `calendar-longitude' if set, otherwise
falls back to the device GPS.  Signals an error if neither is available.
When called from the node list, uses the node at point.
When called from a DM buffer, uses the DM target.
See also `calendar-latitude', `calendar-longitude'."
  (interactive (list (meshtastic--read-node-id)))
  (unless meshtastic--connected
    (user-error "Not connected"))
  (let* ((pos     (meshtastic--get-emacs-position))
         (cmd-id  (meshtastic--cmd-id))
         (alist   `((action . "sendposition")
                    (id     . ,cmd-id)
                    (dest   . ,node-id))))
    (when pos
      (push `(lon . ,(cadr pos)) alist)
      (push `(lat . ,(car  pos)) alist))
    (meshtastic--send-cmd alist)
    (message "Meshtastic: sending position to %s..."
             (meshtastic--node-name node-id))))

;;;; Welcome buffer

(defvar meshtastic-welcome-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "c") #'meshtastic-channels)
    (define-key map (kbd "n") #'meshtastic-nodes)
    (define-key map (kbd "d") #'meshtastic-direct-messages)
    (define-key map (kbd "u") #'meshtastic-unread)
    (define-key map (kbd "g") #'meshtastic-refresh)
    (define-key map (kbd "q") #'quit-window)
    map)
  "Keymap for `meshtastic-welcome-mode'.")

(define-derived-mode meshtastic-welcome-mode special-mode "Meshtastic"
  "Major mode for the Meshtastic welcome screen."
  :group 'meshtastic
  (buffer-disable-undo)
  (setq truncate-lines t))

(defun meshtastic--insert-shortcut (key label)
  "Insert a formatted shortcut KEY with LABEL."
  (insert "  ")
  (insert (propertize (format "[%s]" key)
                      'face 'meshtastic-welcome-key-face))
  (insert (format " %-17s" label)))

(defun meshtastic--welcome-status ()
  "Return the propertized connection status for the welcome buffer."
  (let ((starting (and meshtastic--process
                       (process-live-p meshtastic--process))))
    (cond
     (meshtastic--connected
      (propertize "Connected" 'face 'meshtastic-delivery-confirmed-face))
     (starting
      (propertize "Connecting..." 'face 'meshtastic-delivery-pending-face))
     (t
      (propertize "Disconnected" 'face 'meshtastic-delivery-failed-face)))))

(defun meshtastic--render-welcome ()
  "Render the welcome buffer and return it."
  (let ((buf (get-buffer-create "*Meshtastic*")))
    (with-current-buffer buf
      (unless (derived-mode-p 'meshtastic-welcome-mode)
        (meshtastic-welcome-mode))
      (let ((inhibit-read-only t)
            (pos (point))
            (sep (propertize (format "  %s\n" (make-string 38 ?─))
                             'face 'meshtastic-timestamp-face)))
        (erase-buffer)
        (insert "\n")
        (insert (propertize "  Meshtastic\n"
                            'face 'meshtastic-welcome-title-face))
        (insert (propertize (format "  %s\n" (make-string 38 ?═))
                            'face 'meshtastic-timestamp-face))
        (insert "\n")
        (insert (propertize "  Connection\n"
                            'face 'meshtastic-welcome-heading-face))
        (insert (format "  Port:      %s\n" meshtastic-serial-port))
        (insert (format "  Status:    %s\n" (meshtastic--welcome-status)))
        (when meshtastic--my-long-name
          (insert (format "  Node:      %s%s (%s)\n"
                          meshtastic--my-long-name
                          (if (and meshtastic--my-short-name
                                   (not (string-empty-p
                                         meshtastic--my-short-name)))
                              (format " [%s]" meshtastic--my-short-name)
                            "")
                          meshtastic--my-node-id)))
        (when meshtastic--firmware
          (insert (format "  Firmware:  %s\n" meshtastic--firmware)))
        (when (and meshtastic--connected meshtastic--connected-since)
          (insert (format "  Uptime:    %s\n"
                          (meshtastic--format-duration
                           (float-time (time-subtract
                                        nil meshtastic--connected-since))))))
        (insert "\n")
        (when (> (meshtastic--node-count) 0)
          (insert (propertize "  Statistics\n"
                              'face 'meshtastic-welcome-heading-face))
          (insert (format "  Nodes:     %d (%d online)\n"
                          (meshtastic--node-count)
                          (meshtastic--online-node-count)))
          (when meshtastic--channels
            (insert (format "  Channels:  %d\n"
                            (length (meshtastic--active-channels)))))
          (insert (format "  Messages:  %d\n" (meshtastic--message-count)))
          (let ((unread (meshtastic--unread-total)))
            (insert (format "  Unread:    %s\n"
                            (if (> unread 0)
                                (propertize (number-to-string unread)
                                            'face 'warning)
                              "0"))))
          (insert "\n"))
        (insert sep)
        (insert "\n")
        (meshtastic--insert-shortcut "c" "Channels")
        (meshtastic--insert-shortcut "n" "Nodes")
        (insert "\n")
        (meshtastic--insert-shortcut "d" "Direct messages")
        (meshtastic--insert-shortcut "u" "Unread")
        (insert "\n")
        (meshtastic--insert-shortcut "g" "Refresh")
        (meshtastic--insert-shortcut "q" "Quit")
        (insert "\n\n")
        (insert sep)
        (goto-char (min pos (point-max)))))
    buf))

;;;; Open chat buffers

(defun meshtastic--open-chat (ttype target)
  "Switch to the chat buffer for TTYPE and TARGET with buffered messages."
  (meshtastic--ensure-connected)
  (let ((buf (meshtastic--get-or-create-buffer ttype target)))
    (switch-to-buffer buf)
    (meshtastic--render-messages buf (meshtastic--ring-messages ttype target))
    (meshtastic--mark-read ttype target)
    buf))

(defun meshtastic-open-channel (channel-id)
  "Open a chat buffer for CHANNEL-ID and load buffered messages."
  (meshtastic--open-chat 'channel channel-id))

(defun meshtastic-open-dm (node-id)
  "Open a DM chat buffer with NODE-ID and load buffered messages."
  (meshtastic--open-chat 'dm node-id))

;;;; Entry points

(defun meshtastic--show-list (name mode populate)
  "Show the list buffer NAME in MODE, filled by calling POPULATE."
  (meshtastic--ensure-connected)
  (let ((buf (get-buffer-create name)))
    (with-current-buffer buf
      (unless (derived-mode-p mode)
        (funcall mode))
      (funcall populate))
    (switch-to-buffer buf)))

;;;###autoload
(defun meshtastic-channels ()
  "Show the Meshtastic channel list buffer."
  (interactive)
  (meshtastic--show-list "*Meshtastic: Channels*"
                         #'meshtastic-channel-list-mode
                         #'meshtastic--populate-channel-list))

;;;###autoload
(defun meshtastic-nodes ()
  "Show the Meshtastic node list buffer."
  (interactive)
  (meshtastic--show-list "*Meshtastic: Nodes*"
                         #'meshtastic-node-list-mode
                         #'meshtastic--populate-node-list)
  (meshtastic--send-cmd '((action . "nodes"))))

;;;###autoload
(defun meshtastic-direct-messages ()
  "Show the direct message conversations received or sent this session."
  (interactive)
  (meshtastic--show-list "*Meshtastic: Direct Messages*"
                         #'meshtastic-dm-list-mode
                         #'meshtastic--populate-dm-list))

;;;###autoload
(defun meshtastic-unread ()
  "Show channels and direct messages with unread messages."
  (interactive)
  (meshtastic--show-list "*Meshtastic: Unread*"
                         #'meshtastic-unread-list-mode
                         #'meshtastic--populate-unread-list))

;;;###autoload
(defun meshtastic ()
  "Open the Meshtastic welcome screen and start the bridge if needed."
  (interactive)
  (meshtastic--ensure-connected)
  (switch-to-buffer (meshtastic--render-welcome)))

;;;###autoload
(defun meshtastic-disconnect ()
  "Stop the bridge subprocess and reset all state."
  (interactive)
  (when (and meshtastic--process (process-live-p meshtastic--process))
    (meshtastic--send-cmd '((action . "quit")))
    (sit-for 0.5)
    (when (process-live-p meshtastic--process)
      (delete-process meshtastic--process)))
  (meshtastic--fail-all-outgoing "disconnected")
  (maphash (lambda (_id timer) (cancel-timer timer)) meshtastic--request-timers)
  (setq meshtastic--process          nil
        meshtastic--connected        nil
        meshtastic--connected-since  nil
        meshtastic--my-node-id       nil
        meshtastic--my-long-name     nil
        meshtastic--my-short-name    nil
        meshtastic--firmware         nil
        meshtastic--channels         nil
        meshtastic--chat-buffers     nil)
  (dolist (table (list meshtastic--nodes
                       meshtastic--message-rings
                       meshtastic--unread
                       meshtastic--outgoing
                       meshtastic--my-packet-ids
                       meshtastic--traceroute-entries
                       meshtastic--request-timers
                       meshtastic--telemetry))
    (clrhash table))
  (message "Meshtastic: disconnected"))

(defun meshtastic-refresh ()
  "Refresh the welcome buffer with current state."
  (interactive)
  (meshtastic--render-welcome))

(provide 'meshtastic)
;;; meshtastic.el ends here
