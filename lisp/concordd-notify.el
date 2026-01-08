;;; concordd-notify.el --- Notification tracking for Concordd -*- lexical-binding: t; -*-

;; Copyright (C) 2025 Concordd Project
;; Author: Andrej Novikov
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1"))
;; Keywords: comm, discord, notifications

;;; Commentary:

;; This package provides notification tracking for Concordd with:
;; - Configurable tracking of guilds, channels, forums, and DMs
;; - Unread message counts and mention tracking
;; - Queue-based navigation through unread channels
;; - Modeline integration with click-to-navigate
;; - Automatic clearing when channels are opened
;; - Syncs with Discord's read state (channels marked as read elsewhere are cleared)
;;
;; Usage:
;;   (require 'concordd-notify)
;;   (setq concordd-notify-tracked-guilds '("guild-id-1" "guild-id-2"))
;;   (setq concordd-notify-tracked-channels '("channel-id-1" "channel-id-2"))
;;   (concordd-notify-mode 1)

;;; Code:

(require 'concordd)

;;; Customization

(defgroup concordd-notify nil
  "Notification tracking for Concordd."
  :group 'concordd
  :prefix "concordd-notify-")

(defcustom concordd-notify-tracked-guilds nil
  "List of guild IDs to track for notifications.
If nil, track all guilds."
  :type '(repeat string)
  :group 'concordd-notify)

(defcustom concordd-notify-tracked-channels nil
  "List of channel IDs to track for notifications.
If non-nil, only track these specific channels.
Takes precedence over guild tracking."
  :type '(repeat string)
  :group 'concordd-notify)

(defcustom concordd-notify-track-dms t
  "Whether to track direct messages."
  :type 'boolean
  :group 'concordd-notify)

(defcustom concordd-notify-mentions-only nil
  "Whether to only track messages where you are mentioned."
  :type 'boolean
  :group 'concordd-notify)

(defcustom concordd-notify-modeline-icon "💬"
  "Icon to display in modeline for notifications."
  :type 'string
  :group 'concordd-notify)

;;; Internal variables

(defvar concordd-notify--channel-queue nil
  "Queue of channels with unread messages.
Each element is a plist with :channel-id, :channel-name, :guild-id, :count, :mentions.")

(defvar concordd-notify--total-unread 0
  "Total number of unread messages.")

(defvar concordd-notify--total-mentions 0
  "Total number of mentions.")

(defvar concordd-notify--current-user-id nil
  "Current Discord user ID.")

;;; Core functions

(defun concordd-notify--should-track-p (guild-id channel-id)
  "Return non-nil if we should track messages in GUILD-ID and CHANNEL-ID."
  (cond
   ;; Specific channel tracking takes precedence
   (concordd-notify-tracked-channels
    (member channel-id concordd-notify-tracked-channels))
   ;; DM channels (no guild-id)
   ((null guild-id)
    concordd-notify-track-dms)
   ;; Guild tracking
   (concordd-notify-tracked-guilds
    (member guild-id concordd-notify-tracked-guilds))
   ;; If no specific configuration, track everything
   (t t)))

(defun concordd-notify--find-channel-in-queue (channel-id)
  "Find channel entry in queue by CHANNEL-ID.
Returns cons of (entry . position) or nil if not found."
  (let ((pos 0)
        (found nil))
    (dolist (entry concordd-notify--channel-queue)
      (when (string= (plist-get entry :channel-id) channel-id)
        (setq found (cons entry pos)))
      (setq pos (1+ pos)))
    found))

(defun concordd-notify--add-or-update-channel (channel-id channel-name guild-id mentioned)
  "Add or update channel in notification queue.
CHANNEL-ID and CHANNEL-NAME identify the channel.
GUILD-ID is the guild (nil for DMs).
MENTIONED is non-nil if user was mentioned."
  (let ((found (concordd-notify--find-channel-in-queue channel-id)))
    (if found
        ;; Update existing entry
        (let* ((entry (car found))
               (count (plist-get entry :count))
               (mentions (plist-get entry :mentions)))
          (plist-put entry :count (1+ count))
          (when mentioned
            (plist-put entry :mentions (1+ mentions))))
      ;; Add new entry
      (push (list :channel-id channel-id
                  :channel-name channel-name
                  :guild-id guild-id
                  :count 1
                  :mentions (if mentioned 1 0))
            concordd-notify--channel-queue))))

(defun concordd-notify--recalculate-totals ()
  "Recalculate total unread and mention counts from queue."
  (setq concordd-notify--total-unread 0
        concordd-notify--total-mentions 0)
  (dolist (entry concordd-notify--channel-queue)
    (setq concordd-notify--total-unread
          (+ concordd-notify--total-unread (plist-get entry :count)))
    (setq concordd-notify--total-mentions
          (+ concordd-notify--total-mentions (plist-get entry :mentions)))))

(defun concordd-notify--handle-message-created (params)
  "Handle messageCreated event with PARAMS."
  (let* ((msg (plist-get params :message))
         (channel-id (plist-get msg :channelId))
         (guild-id (plist-get msg :guildId))
         (author (plist-get msg :author))
         (author-id (plist-get author :id))
         (mentions (plist-get msg :mentions))
         (channel-name (or (plist-get params :channelName) "Unknown")))
    
    ;; Ignore messages sent by current user
    (when (and concordd-notify--current-user-id
               (string= author-id concordd-notify--current-user-id))
      (cl-return-from concordd-notify--handle-message-created))
    
    ;; Check if current user is mentioned
    (let ((mentioned (and concordd-notify--current-user-id
                          mentions
                          (member concordd-notify--current-user-id mentions))))
      
      ;; Only track if configured to do so
      (when (concordd-notify--should-track-p guild-id channel-id)
        ;; If mentions-only mode, skip non-mentions
        (unless (and concordd-notify-mentions-only (not mentioned))
          (concordd-notify--add-or-update-channel
           channel-id channel-name guild-id mentioned)
          (concordd-notify--recalculate-totals)
          (force-mode-line-update t))))))

(defun concordd-notify--handle-read-state-updated (params)
  "Handle readStateUpdated event with PARAMS.
When a channel is marked as read, update or remove from notification queue."
  (let* ((channel-id (plist-get params :channelId))
         (mention-count (plist-get params :mentionCount))
         (found (concordd-notify--find-channel-in-queue channel-id)))
    (when found
      (if (and (zerop mention-count))
          ;; No mentions left, remove channel from queue entirely
          (progn
            (setq concordd-notify--channel-queue
                  (delq (car found) concordd-notify--channel-queue))
            (concordd-notify--recalculate-totals)
            (force-mode-line-update t))
        ;; Update mention count but keep channel in queue
        (let ((entry (car found)))
          (plist-put entry :mentions mention-count)
          (concordd-notify--recalculate-totals)
          (force-mode-line-update t))))))

(defun concordd-notify-clear-channel (channel-id)
  "Clear notifications for CHANNEL-ID."
  (let ((found (concordd-notify--find-channel-in-queue channel-id)))
    (when found
      (let ((pos (cdr found)))
        (setq concordd-notify--channel-queue
              (append (seq-take concordd-notify--channel-queue pos)
                      (seq-drop concordd-notify--channel-queue (1+ pos)))))
      (concordd-notify--recalculate-totals)
      (force-mode-line-update t))))

(defun concordd-notify-clear-all ()
  "Clear all notifications."
  (interactive)
  (setq concordd-notify--channel-queue nil
        concordd-notify--total-unread 0
        concordd-notify--total-mentions 0)
  (force-mode-line-update t))

(defun concordd-notify-next-channel ()
  "Open the next channel with unread messages.
Removes that channel from the notification queue."
  (interactive)
  (if (null concordd-notify--channel-queue)
      (message "No unread channels")
    (let* ((entry (car concordd-notify--channel-queue))
           (channel-id (plist-get entry :channel-id))
           (channel-name (plist-get entry :channel-name))
           (guild-id (plist-get entry :guild-id))
           (count (plist-get entry :count)))
      
      ;; Remove from queue
      (setq concordd-notify--channel-queue (cdr concordd-notify--channel-queue))
      (concordd-notify--recalculate-totals)
      (force-mode-line-update t)
      
      ;; Open the channel
      (require 'concordd-ui-v2)
      (concordd-ui-v2-open-channel channel-id channel-name guild-id)
      
      (message "Opening %s (%d unread)" channel-name count))))

;;; Modeline integration

(defun concordd-notify-modeline-segment ()
  "Return modeline segment showing unread counts.
Click to navigate to next unread channel."
  (when (> concordd-notify--total-unread 0)
    (let* ((mention-str (if (> concordd-notify--total-mentions 0)
                            (propertize (format "@%d " concordd-notify--total-mentions)
                                        'face 'error)
                          ""))
           (unread-str (propertize (number-to-string concordd-notify--total-unread)
                                   'face 'warning))
           (segment (concat " "
                            concordd-notify-modeline-icon
                            mention-str
                            unread-str
                            " ")))
      (propertize segment
                  'mouse-face 'mode-line-highlight
                  'help-echo (format "Discord: %d unread, %d mentions\nClick to open next channel"
                                     concordd-notify--total-unread
                                     concordd-notify--total-mentions)
                  'local-map (make-mode-line-mouse-map
                              'mouse-1 #'concordd-notify-next-channel)))))

;;; Auto-clear when opening channels

(defun concordd-notify--auto-clear-channel (&rest args)
  "Automatically clear notifications when a channel is opened.
ARGS should contain channel-id as first argument."
  (when-let ((channel-id (car args)))
    (concordd-notify-clear-channel channel-id)))

;;; Minor mode

;;;###autoload
(define-minor-mode concordd-notify-mode
  "Toggle Discord notification tracking.
When enabled, tracks unread messages and displays them in the modeline."
  :global t
  :group 'concordd-notify
  :lighter nil
  (if concordd-notify-mode
      (progn
        ;; Register a hook to fetch user ID after connection
        (defun concordd-notify--fetch-user-id ()
          "Fetch current user ID after connection."
          (run-with-timer 1 nil  ;; Wait 1 second for daemon Ready event
            (lambda ()
              (concordd-get-current-user
               (lambda (result)
                 (setq concordd-notify--current-user-id (plist-get result :id))))))
          (remove-hook 'concordd-after-connect-hook #'concordd-notify--fetch-user-id))
        (add-hook 'concordd-after-connect-hook #'concordd-notify--fetch-user-id)
        
        ;; Register event handlers
        (concordd-on 'messageCreated #'concordd-notify--handle-message-created)
        (concordd-on 'readStateUpdated #'concordd-notify--handle-read-state-updated)
        
        ;; Add auto-clear advice
        (advice-add 'concordd-ui-v2-open-channel :before
                    #'concordd-notify--auto-clear-channel)
        
        ;; Add to modeline (standard modeline only)
        (unless (featurep 'doom-modeline)
          (add-to-list 'mode-line-misc-info
                       '(:eval (concordd-notify-modeline-segment))))
        
        (message "Concordd notification tracking enabled"))
    
    ;; Disable
    (concordd-off 'messageCreated #'concordd-notify--handle-message-created)
    (concordd-off 'readStateUpdated #'concordd-notify--handle-read-state-updated)
    (advice-remove 'concordd-ui-v2-open-channel #'concordd-notify--auto-clear-channel)
    (setq mode-line-misc-info
          (remove '(:eval (concordd-notify-modeline-segment))
                  mode-line-misc-info))
    (concordd-notify-clear-all)
    (setq concordd-notify--current-user-id nil)
    (message "Concordd notification tracking disabled")))

(provide 'concordd-notify)
;;; concordd-notify.el ends here
