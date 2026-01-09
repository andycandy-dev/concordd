;;; concordd-ui-v2.el --- EWOC-based UI for Concordd -*- lexical-binding: t; -*-

;; Copyright (C) 2025 Concordd Project
;; Author: Andrej Novikov
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1"))
;; Keywords: comm, discord

;;; Commentary:

;; This file provides the new EWOC-based UI implementation for Concordd.
;; It replaces the old buffer-erase-and-rerender approach with incremental
;; updates using EWOC (Emacs Widget for Object Collections).
;;
;; Features:
;; - Incremental message updates (no full buffer refresh)
;; - Cursor position preservation
;; - Rich message formatting (planned)
;; - Better performance for large channels

;;; Code:

(require 'ewoc)
(require 'concordd-message)
(require 'concordd-ewoc)
;; Declare functions to avoid circular dependencies
(declare-function concordd-ipc-on "concordd-ipc")
(declare-function concordd-get-messages "concordd")
(declare-function concordd-send-message "concordd")
(declare-function concordd-list-guilds "concordd")
(declare-function concordd-list-channels "concordd")
(declare-function concordd-get-guild-members "concordd")
(declare-function concordd-get-guild-roles "concordd")

;; Load format module when available
(require 'concordd-format nil t)

;;; Customization

(defgroup concordd-ui-v2 nil
  "Concordd UI v2 (EWOC-based) customization."
  :group 'concordd)

(defcustom concordd-ui-v2-message-limit 100
  "Maximum number of messages to keep in buffer.
Older messages are removed when this limit is exceeded."
  :type 'integer
  :group 'concordd-ui-v2)

(defcustom concordd-ui-v2-load-message-count 50
  "Number of messages to load when opening a channel or loading history."
  :type 'integer
  :group 'concordd-ui-v2)

;;; Buffer-local variables

(defvar-local concordd-message-ewoc nil
  "EWOC containing messages in current buffer.")

(defvar-local concordd-ui-v2-channel-id nil
  "Channel ID for current buffer.")

(defvar-local concordd-ui-v2-channel-name nil
  "Channel name for current buffer.")

(defvar-local concordd-ui-v2-guild-id nil
  "Guild ID for current channel.")

(defvar-local concordd-ui-v2-oldest-message-id nil
  "ID of the oldest message loaded in this buffer.
Used for pagination when loading older messages.")

;;; Mode definition

(defvar concordd-ui-v2-channel-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "n") #'concordd-ui-v2-compose)
    (define-key map (kbd "p") #'concordd-ui-v2-load-older)
    (define-key map (kbd "gr") #'concordd-ui-v2-refresh)
    (define-key map (kbd "q") #'quit-window)
    (define-key map (kbd "RET") #'concordd-ui-v2-compose-reply)
    map)
  "Keymap for concordd-ui-v2-channel-mode.")

(define-derived-mode concordd-ui-v2-channel-mode special-mode "Concordd"
  "Major mode for Concordd channels (v2).
Uses EWOC for efficient message display and incremental updates.

\\{concordd-ui-v2-channel-mode-map}"
  (setq buffer-read-only t)
  (setq-local revert-buffer-function #'concordd-ui-v2-channel-revert)
  ;; Enable visual-line-mode for better long message wrapping
  (visual-line-mode 1)
  
  ;; Evil integration
  (when (bound-and-true-p evil-mode)
    (evil-set-initial-state 'concordd-ui-v2-channel-mode 'normal)))

;;; Channel buffer management

(defun concordd-ui-v2-open-channel (channel-id channel-name &optional guild-id)
  "Open channel with CHANNEL-ID and CHANNEL-NAME in GUILD-ID."
  (interactive)
  (let ((buf (concordd-ui-v2--get-or-create-channel-buffer 
              channel-id channel-name guild-id)))
    (pop-to-buffer buf)
    ;; Load guild cache for mention resolution
    (when guild-id
      (concordd-ui-v2--load-guild-cache guild-id))
    (concordd-ui-v2--load-messages channel-id)))

(defun concordd-ui-v2--get-or-create-channel-buffer (channel-id channel-name guild-id)
  "Get or create buffer for CHANNEL-ID with CHANNEL-NAME in GUILD-ID."
  (or (concordd-ui-v2--find-channel-buffer channel-id)
      (let ((buf (get-buffer-create (format "*Concordd: #%s*" channel-name))))
        (with-current-buffer buf
          (concordd-ui-v2-channel-mode)
          (setq concordd-ui-v2-channel-id channel-id
                concordd-ui-v2-channel-name channel-name
                concordd-ui-v2-guild-id guild-id)
          (concordd-ui-v2--init-ewoc channel-name))
        buf)))

(defun concordd-ui-v2--init-ewoc (channel-name)
  "Initialize EWOC for channel with CHANNEL-NAME."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (setq concordd-message-ewoc
          (ewoc-create #'concordd-message--format
                      (format "════════════════════════════════\n")
                      (format "\n════════════════════════════════\n")))))

(defun concordd-ui-v2--find-channel-buffer (channel-id)
  "Find buffer for CHANNEL-ID."
  (cl-find-if (lambda (buf)
                (with-current-buffer buf
                  (and (eq major-mode 'concordd-ui-v2-channel-mode)
                       (string= concordd-ui-v2-channel-id channel-id))))
              (buffer-list)))

;;; Message state helpers

(defun concordd-ui-v2--set-message-state (msg guild-id prev-author-id)
  "Set MSG state with GUILD-ID and PREV-AUTHOR-ID."
  (setf (concordd-message-state msg)
        (list :guild-id guild-id :prev-author-id prev-author-id)))

;;; Message loading

(defun concordd-ui-v2--load-guild-cache (guild-id)
  "Load members, roles, and channels for GUILD-ID into format cache."
  (when (featurep 'concordd-format)
    (concordd-get-guild-members guild-id
      (lambda (r) (concordd-format-set-guild-cache guild-id (plist-get r :members) nil nil)))
    (concordd-get-guild-roles guild-id
      (lambda (r) (concordd-format-set-guild-cache guild-id nil (plist-get r :roles) nil)))
    (concordd-list-channels guild-id
      (lambda (r) (concordd-format-set-guild-cache guild-id nil nil (plist-get r :channels))))))

(defun concordd-ui-v2--load-messages (channel-id)
  "Load initial messages for CHANNEL-ID."
  (concordd-get-messages
   channel-id
   (lambda (result)
     (concordd-ui-v2--display-messages channel-id (plist-get result :messages)))
   concordd-ui-v2-load-message-count
   nil))

(defun concordd-ui-v2--display-messages (channel-id messages)
  "Display MESSAGES for CHANNEL-ID."
  (when-let ((buf (concordd-ui-v2--find-channel-buffer channel-id)))
    (with-current-buffer buf
      (let ((inhibit-read-only t)
            (prev-author-id nil))
        (dolist (msg-plist (reverse messages))
          (let ((msg (concordd-message-from-plist msg-plist)))
            (concordd-ui-v2--set-message-state msg concordd-ui-v2-guild-id prev-author-id)
            (ewoc-enter-last concordd-message-ewoc msg)
            (setq prev-author-id (plist-get (concordd-message-author msg) :id))
            (when (or (null concordd-ui-v2-oldest-message-id)
                      (string< (concordd-message-id msg) concordd-ui-v2-oldest-message-id))
              (setq concordd-ui-v2-oldest-message-id (concordd-message-id msg)))))
        (goto-char (point-max))))))

(defun concordd-ui-v2-load-older ()
  "Load older messages in current channel."
  (interactive)
  (unless concordd-ui-v2-channel-id
    (user-error "Not in a Concordd channel buffer"))
  
  (let ((current-node (ewoc-locate concordd-message-ewoc (point))))
    (concordd-get-messages
     concordd-ui-v2-channel-id
     (lambda (result)
       (concordd-ui-v2--prepend-messages (plist-get result :messages))
       ;; Try to restore position to the same node
       (when current-node
         (ewoc-goto-node concordd-message-ewoc current-node)))
     concordd-ui-v2-load-message-count
     concordd-ui-v2-oldest-message-id)
    
    (message "Loading older messages...")))

(defun concordd-ui-v2--prepend-messages (messages)
  "Prepend MESSAGES to current buffer's EWOC."
  (let ((inhibit-read-only t)
        (first-node (ewoc-nth concordd-message-ewoc 0))
        (prev-author-id nil))
    (dolist (msg-plist (reverse messages))
      (let ((msg (concordd-message-from-plist msg-plist)))
        (concordd-ui-v2--set-message-state msg concordd-ui-v2-guild-id prev-author-id)
        (ewoc-enter-first concordd-message-ewoc msg)
        (setq prev-author-id (plist-get (concordd-message-author msg) :id))
        (when (or (null concordd-ui-v2-oldest-message-id)
                  (string< (concordd-message-id msg) concordd-ui-v2-oldest-message-id))
          (setq concordd-ui-v2-oldest-message-id (concordd-message-id msg)))))
    ;; Update first existing message's prev-author-id to link grouping
    (when first-node
      (let ((first-msg (ewoc-data first-node)))
        (setf (concordd-message-state first-msg)
              (plist-put (concordd-message-state first-msg) :prev-author-id prev-author-id))
        (ewoc-invalidate concordd-message-ewoc first-node)))))

;;; Event handlers

(defun concordd-ui-v2--handle-message-created (params)
  "Handle messageCreated event with PARAMS."
  (let* ((msg-plist (plist-get params :message))
         (channel-id (plist-get msg-plist :channelId))
         (buf (concordd-ui-v2--find-channel-buffer channel-id)))
    (when buf
      (with-current-buffer buf
        (let* ((inhibit-read-only t)
               (msg (concordd-message-from-plist msg-plist))
               (at-bottom (= (point) (point-max)))
               (last-node (ewoc-nth concordd-message-ewoc -1))
               (prev-author-id (when last-node
                                 (plist-get (concordd-message-author (ewoc-data last-node)) :id))))
          (concordd-ui-v2--set-message-state msg concordd-ui-v2-guild-id prev-author-id)
          (ewoc-enter-last concordd-message-ewoc msg)
          (when at-bottom (goto-char (point-max))))))))

(defun concordd-ui-v2--handle-message-updated (params)
  "Handle messageUpdated event with PARAMS."
  (let* ((msg-plist (plist-get params :message))
         (channel-id (plist-get msg-plist :channelId))
         (message-id (plist-get msg-plist :id))
         (buf (concordd-ui-v2--find-channel-buffer channel-id)))
    (when buf
      (with-current-buffer buf
        (let ((inhibit-read-only t))
          (concordd-ewoc-update-message
           concordd-message-ewoc
           message-id
           (lambda (msg)
             ;; Update message fields
             (setf (concordd-message-content msg) 
                   (plist-get msg-plist :content))
             (setf (concordd-message-edited-timestamp msg)
                   (plist-get msg-plist :editedTimestamp)))))))))

(defun concordd-ui-v2--handle-message-deleted (params)
  "Handle messageDeleted event with PARAMS."
  (let* ((message-id (plist-get params :messageId))
         (channel-id (plist-get params :channelId))
         (buf (concordd-ui-v2--find-channel-buffer channel-id)))
    (when buf
      (with-current-buffer buf
        (let ((inhibit-read-only t))
          (concordd-ewoc-delete-message concordd-message-ewoc message-id))))))

;;; User commands

(defun concordd-ui-v2-compose ()
  "Compose a new message in current channel."
  (interactive)
  (unless concordd-ui-v2-channel-id
    (user-error "Not in a Concordd channel buffer"))
  
  (let ((content (read-string "Message: ")))
    (when (> (length content) 0)
      (concordd-send-message
       concordd-ui-v2-channel-id
       content
       (lambda (_result)
         (message "Message sent"))))))

(defun concordd-ui-v2-compose-reply ()
  "Reply to message at point."
  (interactive)
  (unless concordd-ui-v2-channel-id
    (user-error "Not in a Concordd channel buffer"))
  
  ;; TODO: Get message ID at point from text properties
  (message "Reply functionality not yet implemented"))

(defun concordd-ui-v2-refresh ()
  "Refresh current channel buffer."
  (interactive)
  (unless concordd-ui-v2-channel-id
    (user-error "Not in a Concordd channel buffer"))
  
  (let ((inhibit-read-only t))
    (concordd-ui-v2--init-ewoc concordd-ui-v2-channel-name)
    (setq concordd-ui-v2-oldest-message-id nil)
    (concordd-ui-v2--load-messages concordd-ui-v2-channel-id)
    (message "Refreshed channel")))

(defun concordd-ui-v2-channel-revert (&optional _ignore-auto _noconfirm)
  "Revert function for channel buffers."
  (concordd-ui-v2-refresh))

;;; Browser (placeholder for Phase 3)

(defun concordd-ui-v2-browser ()
  "Show guild/channel browser.
This is a placeholder - full implementation in Phase 3."
  (interactive)
  ;; For now, just show guild list using old UI
  (require 'concordd-ui)
  (concordd-list-guilds
   (lambda (result)
     (let ((guilds (plist-get result :guilds)))
       (concordd-ui-v2--show-simple-guild-list guilds)))))

(defun concordd-ui-v2--show-simple-guild-list (guilds)
  "Show simple GUILDS list (temporary implementation)."
  (let ((buf (get-buffer-create "*Concordd Guilds*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "Concordd Guilds (v2)\n")
        (insert "══════════════════\n\n")
        (dolist (guild guilds)
          (let ((guild-id (plist-get guild :id))
                (guild-name (plist-get guild :name)))
            (insert-button guild-name
                          'action (lambda (_)
                                   (concordd-ui-v2--show-channels guild-id guild-name))
                          'follow-link t)
            (insert "\n"))))
      (goto-char (point-min))
      (special-mode))
    (pop-to-buffer buf)))

(defun concordd-ui-v2--show-channels (guild-id guild-name)
  "Show channels for GUILD-ID and GUILD-NAME."
  (concordd-list-channels
   guild-id
   (lambda (result)
     (let ((channels (plist-get result :channels)))
       (concordd-ui-v2--show-simple-channel-list channels guild-id guild-name)))))

(defun concordd-ui-v2--show-simple-channel-list (channels guild-id guild-name)
  "Show simple CHANNELS list for GUILD-ID and GUILD-NAME."
  (let ((buf (get-buffer-create (format "*Concordd: %s*" guild-name))))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "Channels in %s\n" guild-name))
        (insert "══════════════════\n\n")
        (dolist (channel channels)
          (let* ((channel-id (plist-get channel :id))
                 (channel-name (plist-get channel :name))
                 (channel-type (plist-get channel :type))
                 (icon (cond
                        ((= channel-type 0) "#")    ; Text
                        ((= channel-type 2) "🔊")   ; Voice
                        ((= channel-type 5) "📢")   ; Announcement
                        ((= channel-type 15) "💬")  ; Forum
                        (t nil))))
            ;; Show text, voice, announcement, and forum channels
            (when icon
              (insert "  ")
              (insert-button (format "%s%s" icon channel-name)
                            'action (lambda (_)
                                     (concordd-ui-v2-open-channel 
                                      channel-id channel-name guild-id))
                            'follow-link t)
              (insert "\n"))))
        (insert "\n")
        (insert "Press 'q' to quit\n"))
      (goto-char (point-min))
      (special-mode))
    (pop-to-buffer buf)))

;;; Setup

(defun concordd-ui-v2-setup ()
  "Set up v2 UI event handlers."
  ;; Register event handlers with IPC layer
  (concordd-ipc-on "messageCreated" #'concordd-ui-v2--handle-message-created)
  (concordd-ipc-on "messageUpdated" #'concordd-ui-v2--handle-message-updated)
  (concordd-ipc-on "messageDeleted" #'concordd-ui-v2--handle-message-deleted))

;; Auto-setup on load
(concordd-ui-v2-setup)

(provide 'concordd-ui-v2)
;;; concordd-ui-v2.el ends here
