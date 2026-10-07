;;; meshtastic-test.el --- Tests for meshtastic.el  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Andros Fenollosa

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; ERT tests for meshtastic.el.  The bridge is not started: events are
;; fed to `meshtastic--handle-line' as JSON lines and outgoing commands
;; are captured instead of being written to the subprocess.
;;
;; Run with:
;;   emacs --batch -L . -l tests/meshtastic-test.el \
;;     -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'json)
(require 'meshtastic)

(defvar meshtastic-test--sent nil
  "Commands sent to the bridge during a test, most recent first.")

(defvar meshtastic-test--notifications nil
  "Notifications delivered during a test as (TITLE BODY TYPE) lists.")

(defmacro meshtastic-test--with-session (&rest body)
  "Run BODY in a fresh, connected session with a fake bridge."
  (declare (indent 0))
  `(let ((meshtastic--connected t)
         (meshtastic--connected-since (current-time))
         (meshtastic--process nil)
         (meshtastic--my-node-id "!00000001")
         (meshtastic--my-long-name "Base Camp")
         (meshtastic--my-short-name "BC")
         (meshtastic--firmware nil)
         (meshtastic--nodes (make-hash-table :test 'equal))
         (meshtastic--channels '(((index . 0) (name . "LongFast") (role . 1))))
         (meshtastic--chat-buffers nil)
         (meshtastic--message-rings (make-hash-table :test 'equal))
         (meshtastic--unread (make-hash-table :test 'equal))
         (meshtastic--outgoing (make-hash-table :test 'equal))
         (meshtastic--my-packet-ids (make-hash-table :test 'eql))
         (meshtastic--traceroute-entries (make-hash-table :test 'equal))
         (meshtastic--request-timers (make-hash-table :test 'equal))
         (meshtastic--telemetry (make-hash-table :test 'equal))
         (meshtastic--cmd-counter 0)
         (meshtastic-notify 'all)
         (meshtastic-highlight t)
         (meshtastic-keywords nil)
         (meshtastic-max-message-bytes 200)
         (meshtastic-max-message-parts 3)
         (meshtastic-notify-method
          (lambda (title body type)
            (push (list title body type) meshtastic-test--notifications)))
         (meshtastic-test--sent nil)
         (meshtastic-test--notifications nil))
     (cl-letf (((symbol-function 'meshtastic--send-cmd)
                (lambda (alist) (push alist meshtastic-test--sent)))
               ((symbol-function 'meshtastic--ensure-connected) #'ignore))
       (puthash "!000000aa" '((nodeId . "!000000aa") (nodeNum . 170)
                              (longName . "Ana") (shortName . "AN")
                              (hasPKC . t) (hopsAway . 1)
                              (lastHeard . 0))
                meshtastic--nodes)
       (unwind-protect
           (progn ,@body)
         (dolist (buf (buffer-list))
           (when (string-prefix-p "*Meshtastic" (buffer-name buf))
             (kill-buffer buf)))))))

(defun meshtastic-test--event (alist)
  "Feed ALIST to the bridge event dispatcher as a JSON line."
  (meshtastic--handle-line (json-encode alist)))

(defun meshtastic-test--message (&rest overrides)
  "Return an incoming channel message event, with OVERRIDES applied."
  (let ((msg (list (cons 'type "message")
                   (cons 'id 1001)
                   (cons 'from "!000000aa")
                   (cons 'to "!ffffffff")
                   (cons 'text "hello mesh")
                   (cons 'channel 0)
                   (cons 'rxTime 1700000000))))
    (while overrides
      (setf (alist-get (pop overrides) msg) (pop overrides)))
    msg))

(defun meshtastic-test--hidden-buffer (ttype target)
  "Create the chat buffer for TTYPE and TARGET without displaying it."
  (meshtastic--get-or-create-buffer ttype target))

(defun meshtastic-test--messages-text (buffer)
  "Return the message area of BUFFER as a plain string."
  (with-current-buffer buffer
    (buffer-substring-no-properties (point-min) meshtastic--prompt-start)))

(defun meshtastic-test--last-sent (action)
  "Return the most recent command with ACTION sent to the bridge."
  (seq-find (lambda (cmd) (equal (alist-get 'action cmd) action))
            meshtastic-test--sent))

;;;; Splitting long messages

(ert-deftest meshtastic-test-split-short-text-is-one-part ()
  ;; Given
  (let ((text "short message"))
    ;; When
    (let ((parts (meshtastic--split-message text 200)))
      ;; Then
      (should (equal parts '("short message"))))))

(ert-deftest meshtastic-test-split-long-text-breaks-at-whitespace ()
  ;; Given
  (let ((text (string-join (make-list 30 "abcdefghi") " ")))
    ;; When
    (let ((parts (meshtastic--split-message text 50)))
      ;; Then
      (should (> (length parts) 1))
      (dolist (part parts)
        (should (<= (string-bytes part) 50))
        (should-not (string-prefix-p " " part))
        (should-not (string-suffix-p " " part)))
      (should (equal (string-join parts " ") text)))))

(ert-deftest meshtastic-test-split-counts-bytes-not-characters ()
  ;; Given: each emoji takes 4 bytes in UTF-8
  (let ((text (make-string 100 ?😀)))
    ;; When
    (let ((parts (meshtastic--split-message text 200)))
      ;; Then
      (should (= (length parts) 2))
      (should (= (string-bytes (car parts)) 200)))))

;;;; Rendering

(ert-deftest meshtastic-test-render-keeps-timestamp-and-nick-faces ()
  ;; Given
  (meshtastic-test--with-session
   (let ((buf (meshtastic-test--hidden-buffer 'channel 0)))
     ;; When
     (meshtastic-test--event (meshtastic-test--message))
     ;; Then: regression, an outer nil face used to erase them
     (with-current-buffer buf
       (goto-char (point-min))
       (should (eq (get-text-property (point) 'face)
                   'meshtastic-timestamp-face))
       (search-forward "<Ana>")
       (should (eq (get-text-property (1- (point)) 'face)
                   'meshtastic-nick-other-face))))))

(ert-deftest meshtastic-test-own-message-survives-refresh ()
  ;; Given
  (meshtastic-test--with-session
   (let ((buf (meshtastic-test--hidden-buffer 'channel 0)))
     (with-current-buffer buf
       (goto-char (point-max))
       (insert "sent from emacs")
       (meshtastic-send-input)
       ;; When
       (meshtastic-refresh-chat))
     ;; Then
     (should (string-match-p "<Base Camp> sent from emacs"
                             (meshtastic-test--messages-text buf))))))

(ert-deftest meshtastic-test-own-message-shown-when-buffer-reopened ()
  ;; Given
  (meshtastic-test--with-session
   (let ((buf (meshtastic-test--hidden-buffer 'channel 0)))
     (with-current-buffer buf
       (goto-char (point-max))
       (insert "persisted")
       (meshtastic-send-input))
     (kill-buffer buf)
     ;; When
     (let ((new (meshtastic-open-channel 0)))
       ;; Then
       (should (string-match-p "persisted"
                               (meshtastic-test--messages-text new)))))))

;;;; Sending

(ert-deftest meshtastic-test-send-input-splits-long-text ()
  ;; Given
  (meshtastic-test--with-session
   (let ((meshtastic-max-message-bytes 20)
         (buf (meshtastic-test--hidden-buffer 'channel 0)))
     (with-current-buffer buf
       (goto-char (point-max))
       (insert "one two three four five six seven")
       ;; When
       (meshtastic-send-input))
     ;; Then
     (should (= (length meshtastic-test--sent) 2))
     (dolist (cmd meshtastic-test--sent)
       (should (<= (string-bytes (alist-get 'text cmd)) 20))))))

(ert-deftest meshtastic-test-send-input-refuses-too-many-parts ()
  ;; Given
  (meshtastic-test--with-session
   (let ((meshtastic-max-message-bytes 10)
         (meshtastic-max-message-parts 2)
         (buf (meshtastic-test--hidden-buffer 'channel 0)))
     (with-current-buffer buf
       (goto-char (point-max))
       (insert (make-string 50 ?x))
       ;; When / Then
       (should-error (meshtastic-send-input) :type 'user-error)
       (should (null meshtastic-test--sent))
       ;; The input is kept so it can be shortened.
       (should (equal (buffer-substring-no-properties
                       meshtastic--prompt-end (point-max))
                      (make-string 50 ?x)))))))

(ert-deftest meshtastic-test-dm-send-uses-dest ()
  ;; Given
  (meshtastic-test--with-session
   (let ((buf (meshtastic-test--hidden-buffer 'dm "!000000aa")))
     (with-current-buffer buf
       (goto-char (point-max))
       (insert "private")
       ;; When
       (meshtastic-send-input))
     ;; Then
     (let ((cmd (meshtastic-test--last-sent "send")))
       (should (equal (alist-get 'dest cmd) "!000000aa"))
       (should-not (assq 'channel cmd))))))

;;;; Delivery tracking

(defun meshtastic-test--send-one (ttype target)
  "Send a message to TTYPE and TARGET and return its chat buffer."
  (let ((buf (meshtastic-test--hidden-buffer ttype target)))
    (with-current-buffer buf
      (goto-char (point-max))
      (insert "ping")
      (meshtastic-send-input))
    buf))

(defun meshtastic-test--icon (buffer)
  "Return the delivery icon shown after \"ping\" in BUFFER."
  (with-current-buffer buffer
    (goto-char (point-min))
    (search-forward "ping ")
    (buffer-substring-no-properties (point) (1+ (point)))))

(ert-deftest meshtastic-test-sent-message-starts-pending ()
  ;; Given / When
  (meshtastic-test--with-session
   (let ((buf (meshtastic-test--send-one 'channel 0)))
     ;; Then
     (should (equal (meshtastic-test--icon buf) "·")))))

(ert-deftest meshtastic-test-ack-marks-message-confirmed ()
  ;; Given
  (meshtastic-test--with-session
   (let ((buf (meshtastic-test--send-one 'channel 0)))
     ;; When
     (meshtastic-test--event '((type . "sent") (id . "cmd-1") (packetId . 42)))
     (meshtastic-test--event '((type . "ack") (id . "cmd-1") (ok . t)
                               (reason . "NONE") (from . "!00000001")))
     ;; Then
     (should (equal (meshtastic-test--icon buf) "✓"))
     (with-current-buffer buf
       (goto-char (point-min))
       (search-forward "ping ")
       (should (eq (get-text-property (point) 'face)
                   'meshtastic-delivery-confirmed-face))))))

(ert-deftest meshtastic-test-dm-implicit-ack-is-relayed ()
  ;; Given
  (meshtastic-test--with-session
   (let ((buf (meshtastic-test--send-one 'dm "!000000aa")))
     ;; When: the ACK comes from our own node, not the recipient
     (meshtastic-test--event '((type . "ack") (id . "cmd-1") (ok . t)
                               (reason . "NONE") (from . "!00000001")))
     ;; Then
     (with-current-buffer buf
       (goto-char (point-min))
       (search-forward "ping ")
       (should (eq (get-text-property (point) 'face)
                   'meshtastic-delivery-relayed-face))))))

(ert-deftest meshtastic-test-nak-marks-message-failed-with-reason ()
  ;; Given
  (meshtastic-test--with-session
   (let ((buf (meshtastic-test--send-one 'dm "!000000aa")))
     ;; When
     (meshtastic-test--event '((type . "ack") (id . "cmd-1") (ok . :json-false)
                               (reason . "MAX_RETRANSMIT") (from . "!00000001")))
     ;; Then
     (should (equal (meshtastic-test--icon buf) "✗"))
     (with-current-buffer buf
       (goto-char (point-min))
       (search-forward "ping ")
       (should (string-match-p "MAX_RETRANSMIT"
                               (get-text-property (point) 'help-echo)))))))

(ert-deftest meshtastic-test-bridge-error-marks-message-failed ()
  ;; Given
  (meshtastic-test--with-session
   (let ((buf (meshtastic-test--send-one 'channel 0)))
     ;; When
     (meshtastic-test--event '((type . "error") (id . "cmd-1")
                               (message . "Data payload too big")))
     ;; Then
     (should (equal (meshtastic-test--icon buf) "✗")))))

(ert-deftest meshtastic-test-bridge-stop-fails-pending-messages ()
  ;; Given
  (meshtastic-test--with-session
   (let* ((buf (meshtastic-test--send-one 'channel 0))
          (proc (make-process :name "meshtastic-test" :command '("true"))))
     (setq meshtastic--process proc)
     (while (process-live-p proc) (accept-process-output proc 0.1))
     ;; When
     (meshtastic--process-sentinel proc "finished\n")
     ;; Then
     (should (equal (meshtastic-test--icon buf) "✗"))
     (should (= (hash-table-count meshtastic--outgoing) 0)))))

(ert-deftest meshtastic-test-delivery-state-survives-reopen ()
  ;; Given
  (meshtastic-test--with-session
   (let ((buf (meshtastic-test--send-one 'channel 0)))
     (kill-buffer buf)
     (meshtastic-test--event '((type . "ack") (id . "cmd-1") (ok . t)
                               (reason . "NONE") (from . "!00000001")))
     ;; When
     (let ((new (meshtastic-open-channel 0)))
       ;; Then
       (should (equal (meshtastic-test--icon new) "✓"))))))

;;;; Replies

(ert-deftest meshtastic-test-reply-sends-reply-id-and-clears-prompt ()
  ;; Given
  (meshtastic-test--with-session
   (let ((buf (meshtastic-test--hidden-buffer 'channel 0)))
     (meshtastic-test--event (meshtastic-test--message 'id 777))
     (with-current-buffer buf
       (goto-char (point-min))
       (search-forward "hello")
       (meshtastic-reply)
       (should (string-prefix-p "[reply Ana]"
                                (buffer-substring-no-properties
                                 meshtastic--prompt-start
                                 meshtastic--prompt-end)))
       (insert "hi Ana")
       ;; When
       (meshtastic-send-input)
       ;; Then
       (should (equal (alist-get 'replyId (meshtastic-test--last-sent "send"))
                      777))
       (should (equal (buffer-substring-no-properties
                       meshtastic--prompt-start meshtastic--prompt-end)
                      "#LongFast> "))))))

(ert-deftest meshtastic-test-reply-shows-indicator-with-sender ()
  ;; Given
  (meshtastic-test--with-session
   (let ((buf (meshtastic-test--hidden-buffer 'channel 0)))
     (meshtastic-test--event (meshtastic-test--message 'id 777))
     ;; When
     (meshtastic-test--event (meshtastic-test--message 'id 778 'text "agreed"
                                                       'replyId 777))
     ;; Then
     (should (string-match-p "<Ana> ↩ Ana: agreed"
                             (meshtastic-test--messages-text buf))))))

(ert-deftest meshtastic-test-reply-to-me-is-highlighted-and-notified ()
  ;; Given
  (meshtastic-test--with-session
   (let ((meshtastic-notify 'highlights)
         (buf (meshtastic-test--send-one 'channel 0)))
     (meshtastic-test--event '((type . "sent") (id . "cmd-1") (packetId . 42)))
     ;; When
     (meshtastic-test--event (meshtastic-test--message 'text "pong"
                                                       'replyId 42))
     ;; Then
     (with-current-buffer buf
       (goto-char (point-min))
       (search-forward "pong")
       (should (memq 'meshtastic-highlight-face
                     (ensure-list (get-text-property (1- (point)) 'face)))))
     (should (equal (nth 2 (car meshtastic-test--notifications)) 'reply)))))

(ert-deftest meshtastic-test-reply-to-unsent-message-is-refused ()
  ;; Given
  (meshtastic-test--with-session
   (let ((buf (meshtastic-test--send-one 'channel 0)))
     (with-current-buffer buf
       (goto-char (point-min))
       (search-forward "ping")
       ;; When / Then: no packet id yet
       (should-error (meshtastic-reply) :type 'user-error)))))

;;;; Reactions

(ert-deftest meshtastic-test-reaction-line-follows-anchor ()
  ;; Given
  (meshtastic-test--with-session
   (let ((buf (meshtastic-test--hidden-buffer 'channel 0)))
     (meshtastic-test--event (meshtastic-test--message 'id 777))
     (meshtastic-test--event (meshtastic-test--message 'id 778 'text "second"
                                                       'rxTime 1700000100))
     ;; When
     (meshtastic-test--event (meshtastic-test--message 'id 900 'text "👍"
                                                       'replyId 777 'emoji 1))
     (meshtastic-test--event (meshtastic-test--message 'id 901 'text "❤"
                                                       'from "!00000001"
                                                       'replyId 777 'emoji 1))
     ;; Then: one merged line right below the first message
     (let ((lines (split-string (meshtastic-test--messages-text buf) "\n" t)))
       (should (= (length lines) 3))
       (should (string-match-p "hello mesh" (nth 0 lines)))
       (should (equal (nth 1 lines) "  ↳ 👍 Ana, ❤ Base Camp"))
       (should (string-match-p "second" (nth 2 lines)))))))

(ert-deftest meshtastic-test-react-sends-emoji-flag ()
  ;; Given
  (meshtastic-test--with-session
   (let ((buf (meshtastic-test--hidden-buffer 'channel 0)))
     (meshtastic-test--event (meshtastic-test--message 'id 777))
     (with-current-buffer buf
       (goto-char (point-min))
       (search-forward "hello")
       ;; When
       (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "🎉")))
         (meshtastic-react)))
     ;; Then
     (let ((cmd (meshtastic-test--last-sent "send")))
       (should (equal (alist-get 'text cmd) "🎉"))
       (should (equal (alist-get 'replyId cmd) 777))
       (should (eq (alist-get 'emoji cmd) t)))
     (should (string-match-p "↳ 🎉 Base Camp"
                             (meshtastic-test--messages-text buf))))))

(ert-deftest meshtastic-test-failed-reaction-is-removed ()
  ;; Given
  (meshtastic-test--with-session
   (let ((buf (meshtastic-test--hidden-buffer 'channel 0)))
     (meshtastic-test--event (meshtastic-test--message 'id 777))
     (with-current-buffer buf
       (goto-char (point-min))
       (search-forward "hello")
       (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "🎉")))
         (meshtastic-react)))
     ;; When
     (meshtastic-test--event '((type . "ack") (id . "cmd-1") (ok . :json-false)
                               (reason . "NO_CHANNEL") (from . "!00000001")))
     ;; Then
     (let ((text (meshtastic-test--messages-text buf)))
       (should-not (string-match-p "↳" text))
       (should (string-match-p "Reaction 🎉 failed (NO_CHANNEL)" text))))))

;;;; Notifications and mentions

(ert-deftest meshtastic-test-hidden-buffer-notifies-once ()
  ;; Given: the chat buffer exists but is not displayed
  (meshtastic-test--with-session
   (meshtastic-test--hidden-buffer 'channel 0)
   ;; When
   (meshtastic-test--event (meshtastic-test--message))
   ;; Then: regression, it used to notify twice
   (should (= (length meshtastic-test--notifications) 1))))

(ert-deftest meshtastic-test-message-without-buffer-notifies ()
  ;; Given / When
  (meshtastic-test--with-session
   (meshtastic-test--event (meshtastic-test--message))
   ;; Then
   (should (equal (car meshtastic-test--notifications)
                  '("#LongFast" "Ana: hello mesh" message)))))

(ert-deftest meshtastic-test-notify-nil-is-silent ()
  ;; Given
  (meshtastic-test--with-session
   (let ((meshtastic-notify nil))
     ;; When
     (meshtastic-test--event (meshtastic-test--message))
     ;; Then
     (should (null meshtastic-test--notifications)))))

(ert-deftest meshtastic-test-highlights-ignores-plain-channel-message ()
  ;; Given
  (meshtastic-test--with-session
   (let ((meshtastic-notify 'highlights))
     ;; When
     (meshtastic-test--event (meshtastic-test--message))
     ;; Then
     (should (null meshtastic-test--notifications)))))

(ert-deftest meshtastic-test-highlights-notifies-mention ()
  ;; Given
  (meshtastic-test--with-session
   (let ((meshtastic-notify 'highlights))
     ;; When
     (meshtastic-test--event (meshtastic-test--message
                              'text "anyone at base camp?"))
     ;; Then
     (should (equal (car meshtastic-test--notifications)
                    '("@ #LongFast" "Ana: anyone at base camp?" mention))))))

(ert-deftest meshtastic-test-highlights-notifies-dm ()
  ;; Given
  (meshtastic-test--with-session
   (let ((meshtastic-notify 'highlights))
     ;; When
     (meshtastic-test--event (meshtastic-test--message 'to "!00000001"))
     ;; Then
     (should (equal (nth 2 (car meshtastic-test--notifications)) 'dm)))))

(ert-deftest meshtastic-test-keyword-counts-as-mention ()
  ;; Given
  (let ((meshtastic-keywords '("rescue"))
        (meshtastic--my-long-name "Base Camp"))
    ;; When / Then
    (should (meshtastic--text-mentions-me-p "Need RESCUE now"))
    (should-not (meshtastic--text-mentions-me-p "rescued yesterday"))))

;;;; Unread tracking and lists

(ert-deftest meshtastic-test-unread-counts-hidden-conversations ()
  ;; Given / When
  (meshtastic-test--with-session
   (meshtastic-test--event (meshtastic-test--message 'id 1))
   (meshtastic-test--event (meshtastic-test--message 'id 2))
   ;; Then
   (should (= (gethash '(channel . 0) meshtastic--unread) 2))))

(ert-deftest meshtastic-test-opening-chat-marks-it-read ()
  ;; Given
  (meshtastic-test--with-session
   (meshtastic-test--event (meshtastic-test--message))
   ;; When
   (meshtastic-open-channel 0)
   ;; Then
   (should (null (gethash '(channel . 0) meshtastic--unread)))))

(ert-deftest meshtastic-test-reactions-do-not-count-as-unread ()
  ;; Given / When
  (meshtastic-test--with-session
   (meshtastic-test--event (meshtastic-test--message 'text "👍" 'replyId 5
                                                     'emoji 1))
   ;; Then
   (should (= (meshtastic--unread-total) 0))))

(ert-deftest meshtastic-test-dm-list-includes-own-conversations ()
  ;; Given
  (meshtastic-test--with-session
   (meshtastic-test--send-one 'dm "!000000bb")
   (meshtastic-test--event (meshtastic-test--message 'to "!00000001"))
   ;; When
   (with-temp-buffer
     (meshtastic-dm-list-mode)
     (meshtastic--populate-dm-list)
     ;; Then
     (should (equal (sort (mapcar #'car tabulated-list-entries) #'string<)
                    '("!000000aa" "!000000bb"))))))

(ert-deftest meshtastic-test-unread-list-opens-right-conversation ()
  ;; Given
  (meshtastic-test--with-session
   (meshtastic-test--event (meshtastic-test--message 'to "!00000001"))
   (with-temp-buffer
     (meshtastic-unread-list-mode)
     (meshtastic--populate-unread-list)
     (goto-char (point-min))
     ;; When
     (meshtastic-unread-list-open))
   ;; Then
   (should (eq (window-buffer (selected-window))
               (meshtastic--chat-buffer 'dm "!000000aa")))))

;;;; Node list

(ert-deftest meshtastic-test-node-list-shows-key-and-unknown-hops ()
  ;; Given
  (meshtastic-test--with-session
   (puthash "!000000cc" '((nodeId . "!000000cc") (longName . "Ghost")
                          (hasPKC . :json-false) (hopsAway))
            meshtastic--nodes)
   ;; When
   (with-temp-buffer
     (meshtastic-node-list-mode)
     (meshtastic--populate-node-list)
     ;; Then
     (let ((ana (cadr (assoc "!000000aa" tabulated-list-entries)))
           (ghost (cadr (assoc "!000000cc" tabulated-list-entries))))
       (should (string-match-p "🔑" (aref ana 1)))
       (should-not (string-match-p "🔑" (aref ghost 1)))
       (should (equal (aref ghost 0) "?"))
       (should (meshtastic--sort-by-hops (list "a" ana) (list "c" ghost)))))))

(ert-deftest meshtastic-test-node-list-online-filter ()
  ;; Given
  (meshtastic-test--with-session
   (puthash "!000000dd" `((nodeId . "!000000dd") (longName . "Fresh")
                          (lastHeard . ,(truncate (float-time))))
            meshtastic--nodes)
   (with-temp-buffer
     (meshtastic-node-list-mode)
     ;; When
     (meshtastic-node-list-toggle-online)
     ;; Then
     (should (equal (mapcar #'car tabulated-list-entries) '("!000000dd"))))))

;;;; Traceroute and position

(ert-deftest meshtastic-test-traceroute-failure-replaces-pending ()
  ;; Given
  (meshtastic-test--with-session
   (cl-letf (((symbol-function 'display-buffer) #'ignore))
     (meshtastic-traceroute "!000000aa"))
   ;; When
   (meshtastic-test--event '((type . "traceroute") (id . "cmd-1")
                             (dest . "!000000aa") (error . "NO_RESPONSE")))
   ;; Then
   (with-current-buffer "*Meshtastic: Traceroute*"
     (should (string-match-p "✗ No route (NO_RESPONSE)" (buffer-string)))
     (should-not (string-match-p "Pending" (buffer-string))))
   (should (= (hash-table-count meshtastic--request-timers) 0))))

(ert-deftest meshtastic-test-request-position-reports-coordinates ()
  ;; Given
  (meshtastic-test--with-session
   (meshtastic-request-position "!000000aa")
   (should (equal (alist-get 'action (car meshtastic-test--sent))
                  "requestposition"))
   ;; When
   (let ((shown nil))
     (cl-letf (((symbol-function 'message)
                (lambda (fmt &rest args) (setq shown (apply #'format fmt args)))))
       (meshtastic-test--event '((type . "position") (id . "cmd-1")
                                 (from . "!000000aa") (lat . 39.4699)
                                 (lon . -0.3763) (alt . 15))))
     ;; Then
     (should (equal shown "Meshtastic: Ana is at 39.46990, -0.37630 (15 m)"))
     (should (= (hash-table-count meshtastic--request-timers) 0)))))

;;;; Message info and mode line

(ert-deftest meshtastic-test-message-info-shows-radio-metrics ()
  ;; Given
  (meshtastic-test--with-session
   (let ((buf (meshtastic-test--hidden-buffer 'channel 0)))
     (meshtastic-test--event (meshtastic-test--message 'rxSnr 6.25 'rxRssi -90
                                                       'hopStart 3 'hopLimit 1
                                                       'relayNode 170))
     (with-current-buffer buf
       (goto-char (point-min))
       ;; When
       (cl-letf (((symbol-function 'display-buffer) #'ignore))
         (meshtastic-message-info)))
     ;; Then
     (with-current-buffer "*Meshtastic: Message Info*"
       (let ((text (buffer-string)))
         (should (string-match-p "Hops: +2 (start 3, remaining 1)" text))
         (should (string-match-p "SNR: +6.25 dB" text))
         (should (string-match-p "RSSI: +-90 dBm" text))
         (should (string-match-p "Relay node: 0xaa (Ana)" text)))))))

(ert-deftest meshtastic-test-mode-line-shows-byte-count ()
  ;; Given
  (meshtastic-test--with-session
   (with-current-buffer (meshtastic-test--hidden-buffer 'channel 0)
     (goto-char (point-max))
     ;; When
     (insert "ñu")
     ;; Then
     (should (equal (meshtastic--mode-line-status) "[on] [3 B]")))))

(provide 'meshtastic-test)
;;; meshtastic-test.el ends here
