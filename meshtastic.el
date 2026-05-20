;;; meshtastic.el --- Chat client for Meshtastic LoRa devices via serial  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Andros Fenollosa

;; Author: Andros Fenollosa <hi@andros.dev>
;; Maintainer: Andros Fenollosa <hi@andros.dev>
;; Version: 1.0.0
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
;;   M-x meshtastic           - welcome screen
;;   M-x meshtastic-channels  - list channels
;;   M-x meshtastic-nodes     - list nodes by hops
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
  "Python executable used to launch the bridge script."
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

(defcustom meshtastic-notify t
  "Non-nil means show desktop notifications for new messages."
  :type 'boolean
  :group 'meshtastic)

(defcustom meshtastic-timestamp-format "%H:%M"
  "Format string for message timestamps, passed to `format-time-string'."
  :type 'string
  :group 'meshtastic)

(defcustom meshtastic-message-history 200
  "Number of messages to keep in memory per channel or DM."
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

(defface meshtastic-delivery-confirmed-face
  '((t :foreground "green"))
  "Face for the confirmed delivery indicator."
  :group 'meshtastic)

(defface meshtastic-delivery-failed-face
  '((t :foreground "red"))
  "Face for the failed delivery indicator."
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

(defvar meshtastic--my-node-id nil
  "Node ID string of the local device, e.g. \"!deadbeef\".")

(defvar meshtastic--my-long-name nil
  "Long name of the local device as reported by the firmware.")

(defvar meshtastic--nodes (make-hash-table :test 'equal)
  "Hash table mapping node ID strings to node alists.")

(defvar meshtastic--channels nil
  "List of channel alists fetched from the device.")

(defvar meshtastic--chat-buffers nil
  "Alist of ((TYPE . TARGET) . BUFFER) for open chat buffers.")

(defvar meshtastic--message-rings (make-hash-table :test 'equal)
  "Hash table mapping (TYPE . TARGET) cons to a ring of message alists.")

(defvar meshtastic--cmd-counter 0
  "Monotonic counter for generating unique command IDs.")

(defvar meshtastic--pending-cmds (make-hash-table :test 'equal)
  "Hash table mapping cmd-id string to a delivery callback function.")

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
  "Hash table of rendered message IDs used for deduplication.")

(defvar-local meshtastic--input-ring nil
  "Ring of previous input strings for history navigation.")

(defvar-local meshtastic--input-ring-index 0
  "Current position in `meshtastic--input-ring'.")

(defvar-local meshtastic--pending-send nil
  "Alist of (CMD-ID . MARKER) for messages awaiting delivery confirmation.")

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

(defun meshtastic--node-online-p (last-heard)
  "Return non-nil if LAST-HEARD is within the last 15 minutes."
  (and last-heard (numberp last-heard) (> last-heard 0)
       (< (- (float-time) last-heard) 900)))

;;;; Node and channel helpers

(defun meshtastic--node-name (id)
  "Return a display name for node ID, falling back to ID itself."
  (let ((node (and id (gethash id meshtastic--nodes))))
    (if node
        (or (alist-get 'longName node)
            (alist-get 'shortName node)
            (format "%s" id))
      (format "%s" (or id "?")))))

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

(defun meshtastic--node-count ()
  "Return the number of nodes in the in-memory cache."
  (hash-table-count meshtastic--nodes))

(defun meshtastic--is-self-p (msg)
  "Return non-nil if MSG was sent by the local device."
  (let ((from (alist-get 'from msg)))
    (and meshtastic--my-node-id from
         (equal from meshtastic--my-node-id))))

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
  (let ((key (cons ttype target)))
    (let ((ring (or (gethash key meshtastic--message-rings)
                    (let ((r (make-ring meshtastic-message-history)))
                      (puthash key r meshtastic--message-rings)
                      r))))
      (ring-insert ring msg))))

(defun meshtastic--ring-messages (ttype target)
  "Return all buffered messages for TTYPE and TARGET in chronological order."
  (let* ((key (cons ttype target))
         (ring (gethash key meshtastic--message-rings)))
    (when ring
      (let ((msgs nil))
        (dotimes (i (ring-length ring))
          (push (ring-ref ring i) msgs))
        msgs))))

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
  (let ((buf (concat (or (process-get proc 'partial) "") string)))
    (let ((lines (split-string buf "\n")))
      (process-put proc 'partial (car (last lines)))
      (dolist (line (butlast lines))
        (unless (string-empty-p (string-trim line))
          (meshtastic--handle-line line))))))

(defun meshtastic--process-sentinel (proc event)
  "Handle bridge PROC lifecycle EVENT."
  (unless (process-live-p proc)
    (when (eq meshtastic--process proc)
      (setq meshtastic--connected nil
            meshtastic--process nil)
      (message "Meshtastic: bridge stopped (%s)" (string-trim event))
      (dolist (entry meshtastic--chat-buffers)
        (let ((buf (cdr entry)))
          (when (buffer-live-p buf)
            (meshtastic--insert-msg buf nil nil
                                    "Bridge disconnected" nil t)))))))

(defun meshtastic--handle-line (line)
  "Parse a JSON LINE from the bridge and dispatch to the correct handler."
  (condition-case _err
      (let* ((json-object-type 'alist)
             (json-array-type 'list)
             (json-key-type 'symbol)
             (obj (json-read-from-string line))
             (type (alist-get 'type obj)))
        (pcase type
          ("connected" (meshtastic--on-connected obj))
          ("message"   (meshtastic--on-message obj))
          ("nodes"     (meshtastic--on-nodes obj))
          ("channels"  (meshtastic--on-channels obj))
          ("info"      (meshtastic--on-info obj))
          ("sent"      (meshtastic--on-sent obj))
          ("error"     (message "Meshtastic bridge: %s"
                                (alist-get 'message obj)))))
    (error (message "Meshtastic bridge stderr: %s" line))))

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
        meshtastic--my-node-id (alist-get 'nodeId obj)
        meshtastic--my-long-name (alist-get 'longName obj))
  (meshtastic--send-cmd '((action . "channels")))
  (meshtastic--send-cmd '((action . "nodes")))
  (message "Meshtastic: connected as %s (%s)"
           (or meshtastic--my-long-name "?")
           (or meshtastic--my-node-id "?"))
  (let ((buf (get-buffer "*Meshtastic*")))
    (when (buffer-live-p buf)
      (meshtastic--render-welcome))))

(defun meshtastic--on-message (obj)
  "Handle an incoming message OBJ from the bridge."
  (let* ((from (alist-get 'from obj))
         (to   (alist-get 'to obj))
         (text (alist-get 'text obj))
         (channel (or (alist-get 'channel obj) 0))
         (ttype (if (meshtastic--broadcast-p to) 'channel 'dm))
         (target (if (eq ttype 'channel) channel from)))
    (meshtastic--ring-push ttype target obj)
    (let ((buf (cdr (assoc (cons ttype target) meshtastic--chat-buffers))))
      (when (buffer-live-p buf)
        (meshtastic--render-messages buf (list obj)))
      (unless (and (buffer-live-p buf) (get-buffer-window buf))
        (meshtastic--notify (meshtastic--node-name from)
                            (or text "") ttype target)))))

(defun meshtastic--on-nodes (obj)
  "Handle a nodes data OBJ from the bridge."
  (let ((data (alist-get 'data obj)))
    (when (listp data)
      (clrhash meshtastic--nodes)
      (dolist (node data)
        (let ((id (alist-get 'nodeId node)))
          (when (and id (not (string-empty-p id)))
            (puthash id node meshtastic--nodes))))))
  (let ((buf (get-buffer "*Meshtastic: Nodes*")))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (meshtastic--populate-node-list))))
  (let ((buf (get-buffer "*Meshtastic*")))
    (when (buffer-live-p buf)
      (meshtastic--render-welcome))))

(defun meshtastic--on-channels (obj)
  "Handle a channels data OBJ from the bridge."
  (setq meshtastic--channels (alist-get 'data obj))
  (let ((buf (get-buffer "*Meshtastic: Channels*")))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (meshtastic--populate-channel-list))))
  (let ((buf (get-buffer "*Meshtastic*")))
    (when (buffer-live-p buf)
      (meshtastic--render-welcome))))

(defun meshtastic--on-info (obj)
  "Handle a device info OBJ from the bridge."
  (setq meshtastic--my-node-id  (alist-get 'nodeId obj)
        meshtastic--my-long-name (alist-get 'longName obj)))

(defun meshtastic--on-sent (obj)
  "Handle a sent confirmation OBJ from the bridge."
  (let* ((cmd-id (alist-get 'id obj))
         (cb (and cmd-id (gethash cmd-id meshtastic--pending-cmds))))
    (when cb
      (remhash cmd-id meshtastic--pending-cmds)
      (funcall cb 'confirmed))))

;;;; Delivery icons

(defun meshtastic--delivery-icon (state)
  "Return a propertized delivery icon string for STATE."
  (let ((icon (pcase state ('confirmed "✓") ('failed "✗") (_ "·")))
        (face (pcase state
                ('confirmed 'meshtastic-delivery-confirmed-face)
                ('failed    'meshtastic-delivery-failed-face)
                (_          'meshtastic-delivery-pending-face))))
    (propertize icon 'face face 'read-only t 'rear-nonsticky t)))

(defun meshtastic--update-delivery (cmd-id state buffer)
  "Replace the delivery icon for CMD-ID with STATE in BUFFER."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((entry (assoc cmd-id meshtastic--pending-send)))
        (when entry
          (let ((marker (cdr entry))
                (inhibit-read-only t))
            (when (and marker (marker-buffer marker))
              (save-excursion
                (goto-char marker)
                (delete-char 1)
                (insert (meshtastic--delivery-icon state)))))
          (setq meshtastic--pending-send
                (delq entry meshtastic--pending-send)))))))

;;;; API commands

(defun meshtastic--api-send (text channel dest callback)
  "Send TEXT to CHANNEL index (integer) or DEST node ID (string).
Call CALLBACK with symbol `confirmed' or `failed' when the bridge responds."
  (let* ((cmd-id (meshtastic--cmd-id))
         (alist (list (cons 'action "send")
                      (cons 'text text)
                      (cons 'id cmd-id))))
    (when (and channel (not dest))
      (push (cons 'channel channel) alist))
    (when dest
      (push (cons 'dest dest) alist))
    (when callback
      (puthash cmd-id callback meshtastic--pending-cmds))
    (meshtastic--send-cmd alist)
    cmd-id))

(defun meshtastic--api-nodes ()
  "Request an updated node list from the bridge."
  (meshtastic--send-cmd '((action . "nodes"))))

(defun meshtastic--api-channels ()
  "Request an updated channel list from the bridge."
  (meshtastic--send-cmd '((action . "channels"))))

;;;; Chat mode

(defvar meshtastic-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET")   #'meshtastic-send-input)
    (define-key map (kbd "M-p")   #'meshtastic-previous-input)
    (define-key map (kbd "M-n")   #'meshtastic-next-input)
    (define-key map (kbd "C-c C-l") #'meshtastic-refresh-chat)
    map)
  "Keymap for `meshtastic-mode'.")

(define-derived-mode meshtastic-mode fundamental-mode "MeshChat"
  "Major mode for Meshtastic chat buffers.
Provides an input prompt with message history above."
  :group 'meshtastic
  (setq-local meshtastic--prompt-start (make-marker))
  (setq-local meshtastic--prompt-end (make-marker))
  (setq-local meshtastic--input-ring (make-ring 64))
  (setq-local meshtastic--input-ring-index 0)
  (setq-local meshtastic--seen-ids (make-hash-table :test 'equal))
  (setq-local meshtastic--pending-send nil)
  (setq mode-line-process
        '(" " (:eval (if meshtastic--connected "[on]" "[off]")))))

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

(defun meshtastic--insert-msg (buffer ts sender text
                                      &optional selfp sysp)
  "Insert a chat line into BUFFER.
TS is a unix timestamp, SENDER the display name, TEXT the message body.
SELFP non-nil marks the message as from the local node.
SYSP non-nil renders a system notification line instead."
  (meshtastic--insert-at-prompt
   buffer
   (lambda ()
     (insert
      (propertize
       (if sysp
           (format "*** %s\n" text)
         (concat
          (propertize (format "[%s] "
                              (if ts (meshtastic--format-time ts) "--:--"))
                      'face 'meshtastic-timestamp-face)
          (propertize (format "<%s> " sender)
                      'face (if selfp
                                'meshtastic-nick-self-face
                              'meshtastic-nick-other-face))
          text "\n"))
       'read-only t
       'rear-nonsticky t
       'front-sticky t
       'face (when sysp 'meshtastic-system-face)
       'meshtastic-msg-text text
       'meshtastic-sender sender)))))

(defun meshtastic--insert-sent-msg (buffer ts sender text cmd-id)
  "Insert an outgoing message with delivery tracking into BUFFER.
TS is the timestamp, SENDER the display name, TEXT the content.
CMD-ID is used to update the delivery icon when the bridge confirms."
  (meshtastic--insert-at-prompt
   buffer
   (lambda ()
     (insert
      (propertize
       (concat
        (propertize (format "[%s] "
                            (if ts (meshtastic--format-time ts) "--:--"))
                    'face 'meshtastic-timestamp-face)
        (propertize (format "<%s> " sender)
                    'face 'meshtastic-nick-self-face)
        text " ")
       'read-only t 'rear-nonsticky t 'front-sticky t
       'meshtastic-msg-text text))
     (let ((icon-pos (point)))
       (insert (meshtastic--delivery-icon 'pending))
       (insert (propertize "\n" 'read-only t 'rear-nonsticky t))
       (when cmd-id
         (push (cons cmd-id (copy-marker icon-pos))
               meshtastic--pending-send))))))

(defun meshtastic--render-messages (buffer messages)
  "Render MESSAGES into BUFFER, skipping already-seen message IDs."
  (when (and (buffer-live-p buffer) messages)
    (let ((sorted (sort (copy-sequence messages)
                        (lambda (a b)
                          (< (or (alist-get 'rxTime a) 0)
                             (or (alist-get 'rxTime b) 0))))))
      (dolist (msg sorted)
        (let ((id (alist-get 'id msg)))
          (unless (and id
                       (with-current-buffer buffer
                         (gethash id meshtastic--seen-ids)))
            (let* ((from   (alist-get 'from msg))
                   (sender (meshtastic--node-name from))
                   (text   (or (alist-get 'text msg) ""))
                   (ts     (alist-get 'rxTime msg))
                   (selfp  (meshtastic--is-self-p msg)))
              (meshtastic--insert-msg buffer ts sender text selfp)
              (unless (or selfp (get-buffer-window buffer))
                (with-current-buffer buffer
                  (meshtastic--notify sender text
                                      meshtastic--target-type
                                      meshtastic--target))))
            (when id
              (with-current-buffer buffer
                (puthash id t meshtastic--seen-ids)))))))))

;;;; Prompt

(defun meshtastic--prompt-string ()
  "Return the prompt string for the current chat buffer."
  (pcase meshtastic--target-type
    ('channel (format "#%s> " (meshtastic--channel-name meshtastic--target)))
    ('dm      (format "%s> "  (meshtastic--node-name meshtastic--target)))
    (_        "Meshtastic> ")))

(defun meshtastic--setup-prompt ()
  "Insert the read-only input prompt at the end of the current buffer."
  (goto-char (point-max))
  (let ((start (point))
        (txt   (meshtastic--prompt-string)))
    (insert (propertize txt
                        'face 'meshtastic-prompt-face
                        'read-only t
                        'front-sticky t
                        'rear-nonsticky t))
    (set-marker meshtastic--prompt-start start)
    (set-marker meshtastic--prompt-end (point))))

;;;; Input handling

(defun meshtastic-send-input ()
  "Send the text typed after the prompt."
  (interactive)
  (if (< (point) meshtastic--prompt-end)
      (goto-char (point-max))
    (let ((input (buffer-substring-no-properties
                  meshtastic--prompt-end (point-max))))
      (when (string-blank-p input)
        (user-error "Empty message"))
      (ring-insert meshtastic--input-ring input)
      (setq meshtastic--input-ring-index 0)
      (let ((inhibit-read-only t))
        (delete-region meshtastic--prompt-end (point-max)))
      (meshtastic--send-text input))))

(defun meshtastic--send-text (text)
  "Send TEXT to the target of the current chat buffer."
  (unless meshtastic--connected
    (user-error "Meshtastic is not connected"))
  (let* ((buf    (current-buffer))
         (target meshtastic--target)
         (ttype  meshtastic--target-type)
         (sender (or meshtastic--my-long-name
                     meshtastic--my-node-id
                     "me"))
         (cmd-id (meshtastic--cmd-id)))
    (meshtastic--insert-sent-msg buf (float-time) sender text cmd-id)
    (pcase ttype
      ('channel
       (meshtastic--api-send
        text target nil
        (lambda (state)
          (meshtastic--update-delivery cmd-id state buf))))
      ('dm
       (meshtastic--api-send
        text nil target
        (lambda (state)
          (meshtastic--update-delivery cmd-id state buf))))
      (_ (user-error "No target set for this buffer")))))

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

;;;; Buffer management

(defun meshtastic--buffer-name (ttype target)
  "Return the buffer name for chat type TTYPE and TARGET."
  (pcase ttype
    ('channel (format "*Meshtastic: #%s*" (meshtastic--channel-name target)))
    ('dm      (format "*Meshtastic: DM %s*" (meshtastic--node-name target)))))

(defun meshtastic--get-or-create-buffer (ttype target)
  "Return an existing or new chat buffer for TTYPE and TARGET."
  (let* ((name (meshtastic--buffer-name ttype target))
         (buf  (get-buffer name)))
    (if (and buf (buffer-live-p buf))
        buf
      (setq buf (get-buffer-create name))
      (with-current-buffer buf
        (meshtastic-mode)
        (setq meshtastic--target target
              meshtastic--target-type ttype)
        (meshtastic--setup-prompt))
      (push (cons (cons ttype target) buf) meshtastic--chat-buffers)
      buf)))

(defun meshtastic-refresh-chat ()
  "Re-render buffered messages in the current chat buffer."
  (interactive)
  (unless meshtastic--target
    (user-error "Not a chat buffer"))
  (let ((msgs (meshtastic--ring-messages meshtastic--target-type
                                         meshtastic--target)))
    (when msgs
      (meshtastic--render-messages (current-buffer) msgs)))
  (message "Meshtastic: refreshed"))

;;;; Notifications

(defun meshtastic--notify (sender text target-type target)
  "Show a desktop notification for a message from SENDER.
TEXT is the message body; TARGET-TYPE and TARGET identify the conversation."
  (when meshtastic-notify
    (let ((title (pcase target-type
                   ('channel (format "#%s" (meshtastic--channel-name target)))
                   ('dm sender)
                   (_ "Meshtastic")))
          (body  (truncate-string-to-width
                  (format "%s: %s" sender text) 100 nil nil "...")))
      (notifications-notify
       :title title
       :body body
       :app-name "Meshtastic"
       :category "im.received"
       :urgency 'normal))))

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
        [("ID" 4 t) ("Name" 20 t) ("Role" 12 t)])
  (setq tabulated-list-padding 2)
  (tabulated-list-init-header))

(defun meshtastic-channel-list-open-by-number ()
  "Open the channel whose number matches the digit key pressed."
  (interactive)
  (meshtastic-open-channel (- last-command-event ?0)))

(defun meshtastic-channel-list-open ()
  "Open a chat buffer for the channel at point."
  (interactive)
  (let ((entry (tabulated-list-get-entry)))
    (when entry
      (meshtastic-open-channel (string-to-number (aref entry 0))))))

(defun meshtastic-channel-list-refresh ()
  "Request an updated channel list from the device."
  (interactive)
  (meshtastic--api-channels)
  (message "Meshtastic: refreshing channels..."))

(defun meshtastic--populate-channel-list ()
  "Fill the channel list buffer from the in-memory channel cache."
  (let ((role-names '((0 . "Disabled") (1 . "Primary") (2 . "Secondary"))))
    (setq tabulated-list-entries
          (mapcar
           (lambda (ch)
             (let ((idx  (or (alist-get 'index ch) 0))
                   (name (or (alist-get 'name  ch) ""))
                   (role (or (alist-get 'role  ch) 0)))
               (list idx
                     (vector (number-to-string idx)
                             name
                             (or (cdr (assq role role-names))
                                 (format "%d" role))))))
           (seq-filter (lambda (ch) (> (or (alist-get 'role ch) 0) 0))
                       meshtastic--channels)))
    (tabulated-list-print t)))

;;;; Node list mode

(defvar meshtastic-node-list-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map (kbd "RET") #'meshtastic-node-list-open)
    (define-key map (kbd "g")   #'meshtastic-node-list-refresh)
    (define-key map (kbd "t")   #'meshtastic-traceroute)
    map)
  "Keymap for `meshtastic-node-list-mode'.")

(define-derived-mode meshtastic-node-list-mode tabulated-list-mode
  "MeshNodes"
  "Major mode for listing Meshtastic mesh nodes sorted by hop count."
  :group 'meshtastic
  (setq tabulated-list-format
        [("Hops" 5 meshtastic--sort-by-hops)
         ("Name" 30 t)
         ("Node ID" 14 t)
         ("Last heard" 12 t)])
  (setq tabulated-list-padding 2)
  (setq tabulated-list-sort-key '("Hops"))
  (tabulated-list-init-header))

(defun meshtastic--sort-by-hops (a b)
  "Sort tabulated entries A and B by hop count ascending."
  (< (string-to-number (aref (cadr a) 0))
     (string-to-number (aref (cadr b) 0))))

(defun meshtastic-node-list-open ()
  "Open a DM chat buffer with the node at point."
  (interactive)
  (let ((entry (tabulated-list-get-entry)))
    (when entry
      (meshtastic-open-dm (aref entry 2)))))

(defun meshtastic-node-list-refresh ()
  "Request an updated node list from the device."
  (interactive)
  (meshtastic--api-nodes)
  (message "Meshtastic: refreshing nodes..."))

(defun meshtastic--populate-node-list ()
  "Fill the node list buffer from the in-memory node cache."
  (let ((entries nil))
    (maphash
     (lambda (_key node)
       (let* ((node-id    (alist-get 'nodeId node))
              (hops       (or (alist-get 'hopsAway node) 0))
              (name       (or (alist-get 'longName  node)
                              (alist-get 'shortName node) ""))
              (last-heard (alist-get 'lastHeard node))
              (indicator  (if (meshtastic--node-online-p last-heard)
                              "🟢" "⚫")))
         (push (list node-id
                     (vector (number-to-string hops)
                             (format "%s %s" indicator name)
                             (or node-id "")
                             (meshtastic--format-last-heard last-heard)))
               entries)))
     meshtastic--nodes)
    (setq tabulated-list-entries entries)
    (tabulated-list-print t)))

;;;; Node actions

(defun meshtastic--node-id-at-point ()
  "Return the node ID string from the tabulated-list entry at point."
  (let ((entry (tabulated-list-get-entry)))
    (when (and entry (> (length entry) 2))
      (aref entry 2))))

(defun meshtastic-traceroute ()
  "Send a traceroute to the node at point using the meshtastic CLI."
  (interactive)
  (let ((node-id (meshtastic--node-id-at-point)))
    (if node-id
        (progn
          (message "Meshtastic: traceroute to %s..." node-id)
          (make-process
           :name "meshtastic-traceroute"
           :command (list "meshtastic"
                          "--port" meshtastic-serial-port
                          "--traceroute" node-id)
           :noquery t
           :filter (lambda (_proc str)
                     (message "Traceroute: %s" (string-trim str)))))
      (user-error "No node at point"))))

;;;; Welcome buffer

(defvar meshtastic-welcome-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "c") #'meshtastic-channels)
    (define-key map (kbd "n") #'meshtastic-nodes)
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

(defun meshtastic--render-welcome ()
  "Render the welcome buffer and return it."
  (let ((buf (get-buffer-create "*Meshtastic*")))
    (with-current-buffer buf
      (unless (derived-mode-p 'meshtastic-welcome-mode)
        (meshtastic-welcome-mode))
      (let ((inhibit-read-only t)
            (sep (propertize (format "  %s\n" (make-string 38 ?-))
                             'face 'meshtastic-timestamp-face)))
        (erase-buffer)
        (insert "\n")
        (insert (propertize "  Meshtastic\n"
                            'face 'meshtastic-welcome-title-face))
        (insert (propertize (format "  %s\n" (make-string 38 ?=))
                            'face 'meshtastic-timestamp-face))
        (insert "\n")
        (insert (propertize "  Connection\n"
                            'face 'meshtastic-welcome-heading-face))
        (insert (format "  Port:      %s\n" meshtastic-serial-port))
        (insert (format "  Status:    %s\n"
                        (propertize
                         (cond
                          (meshtastic--connected "Connected")
                          ((and meshtastic--process
                                (process-live-p meshtastic--process))
                           "Connecting...")
                          (t "Disconnected"))
                         'face (cond
                                (meshtastic--connected
                                 'meshtastic-delivery-confirmed-face)
                                ((and meshtastic--process
                                      (process-live-p meshtastic--process))
                                 'meshtastic-delivery-pending-face)
                                (t
                                 'meshtastic-delivery-failed-face)))))
        (when meshtastic--my-long-name
          (insert (format "  Node:      %s (%s)\n"
                          meshtastic--my-long-name
                          meshtastic--my-node-id)))
        (insert "\n")
        (when (> (meshtastic--node-count) 0)
          (insert (propertize "  Statistics\n"
                              'face 'meshtastic-welcome-heading-face))
          (insert (format "  Nodes:     %d\n" (meshtastic--node-count)))
          (when meshtastic--channels
            (insert (format "  Channels:  %d\n"
                            (length
                             (seq-filter
                              (lambda (c) (> (or (alist-get 'role c) 0) 0))
                              meshtastic--channels)))))
          (insert "\n"))
        (insert sep)
        (insert "\n")
        (meshtastic--insert-shortcut "c" "Channels")
        (meshtastic--insert-shortcut "n" "Nodes")
        (insert "\n")
        (meshtastic--insert-shortcut "g" "Refresh")
        (meshtastic--insert-shortcut "q" "Quit")
        (insert "\n\n")
        (insert sep)
        (goto-char (point-min))))
    buf))

;;;; Open chat buffers

(defun meshtastic-open-channel (channel-id)
  "Open a chat buffer for CHANNEL-ID and load buffered messages."
  (meshtastic--ensure-connected)
  (let ((buf (meshtastic--get-or-create-buffer 'channel channel-id)))
    (switch-to-buffer buf)
    (let ((msgs (meshtastic--ring-messages 'channel channel-id)))
      (when msgs
        (meshtastic--render-messages buf msgs)))))

(defun meshtastic-open-dm (node-id)
  "Open a DM chat buffer with NODE-ID and load buffered messages."
  (meshtastic--ensure-connected)
  (let ((buf (meshtastic--get-or-create-buffer 'dm node-id)))
    (switch-to-buffer buf)
    (let ((msgs (meshtastic--ring-messages 'dm node-id)))
      (when msgs
        (meshtastic--render-messages buf msgs)))))

;;;; Entry points

;;;###autoload
(defun meshtastic-channels ()
  "Show the Meshtastic channel list buffer."
  (interactive)
  (meshtastic--ensure-connected)
  (let ((buf (get-buffer-create "*Meshtastic: Channels*")))
    (with-current-buffer buf
      (unless (derived-mode-p 'meshtastic-channel-list-mode)
        (meshtastic-channel-list-mode))
      (meshtastic--populate-channel-list))
    (switch-to-buffer buf)))

;;;###autoload
(defun meshtastic-nodes ()
  "Show the Meshtastic node list buffer."
  (interactive)
  (meshtastic--ensure-connected)
  (meshtastic--api-nodes)
  (let ((buf (get-buffer-create "*Meshtastic: Nodes*")))
    (with-current-buffer buf
      (unless (derived-mode-p 'meshtastic-node-list-mode)
        (meshtastic-node-list-mode))
      (meshtastic--populate-node-list))
    (switch-to-buffer buf)))

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
  (setq meshtastic--process     nil
        meshtastic--connected   nil
        meshtastic--my-node-id  nil
        meshtastic--my-long-name nil
        meshtastic--channels    nil
        meshtastic--chat-buffers nil)
  (clrhash meshtastic--nodes)
  (clrhash meshtastic--message-rings)
  (clrhash meshtastic--pending-cmds)
  (message "Meshtastic: disconnected"))

(defun meshtastic-refresh ()
  "Refresh the welcome buffer with current state."
  (interactive)
  (meshtastic--render-welcome))

(provide 'meshtastic)
;;; meshtastic.el ends here
