#!/usr/bin/env bash
# Example script demonstrating discord.el usage from Emacs Lisp

cat << 'EOF'
;; Example discord.el Usage
;; Copy and paste into *scratch* buffer and evaluate with C-x C-e

;; 1. Load discord.el
(load-file "/path/to/discordo/discord.el")

;; 2. Connect to daemon
(discord-connect)
;; => Connected to Discord daemon at /tmp/discordo-daemon.sock

;; 3. Test connection
(discord-ping
 (lambda (result)
   (message "Daemon status: %s at %s"
            (plist-get result :status)
            (plist-get result :timestamp))))

;; 4. List all guilds
(discord-list-guilds
 (lambda (result)
   (let ((guilds (plist-get result :guilds)))
     (message "You are in %d guild(s)" (length guilds))
     (dolist (guild guilds)
       (message "  - %s (ID: %s)"
                (plist-get guild :name)
                (plist-get guild :id))))))

;; 5. List channels in a guild (replace with your guild ID)
(setq my-guild-id "YOUR_GUILD_ID")

(discord-list-channels
 my-guild-id
 (lambda (result)
   (let ((channels (plist-get result :channels)))
     (message "Found %d channel(s)" (length channels))
     (dolist (ch channels)
       (let ((name (plist-get ch :name))
             (type (plist-get ch :type))
             (unread (plist-get ch :unread)))
         (when (= type 0)  ; Text channels only
           (message "  #%s%s (ID: %s)"
                    name
                    (if unread " [UNREAD]" "")
                    (plist-get ch :id))))))))

;; 6. Get messages from a channel (replace with your channel ID)
(setq my-channel-id "YOUR_CHANNEL_ID")

(discord-get-messages
 my-channel-id
 (lambda (result)
   (let ((messages (plist-get result :messages)))
     (message "Loaded %d message(s)" (length messages))
     (dolist (msg (seq-take messages 5))  ; Show first 5
       (let* ((author (plist-get msg :author))
              (username (plist-get author :username))
              (content (plist-get msg :content)))
         (message "[%s] %s: %s"
                  (plist-get msg :timestamp)
                  username
                  content)))))
 10  ; Get last 10 messages
 nil)

;; 7. Send a message
(discord-send-message
 my-channel-id
 "Hello from Emacs! 👋"
 (lambda (result)
   (let ((msg (plist-get result :message)))
     (message "Message sent! ID: %s" (plist-get msg :id)))))

;; 8. Reply to a message (replace with message ID you want to reply to)
(setq message-to-reply-to "MESSAGE_ID")

(discord-reply-to-message
 my-channel-id
 message-to-reply-to
 "This is a reply from Emacs!"
 (lambda (result)
   (message "Reply sent!")))

;; 9. Set up event handlers for real-time updates
(discord-on 'messageCreated
  (lambda (params)
    (let* ((msg (plist-get params :message))
           (author (plist-get msg :author))
           (content (plist-get msg :content))
           (channel-id (plist-get msg :channelId)))
      (message "New message in %s from %s: %s"
               channel-id
               (plist-get author :username)
               content))))

(discord-on 'connectionStatusChanged
  (lambda (params)
    (message "Discord connection status: %s" (plist-get params :status))))

;; 10. Open the interactive UI
(discord-browse)
;; This opens a buffer where you can:
;; - Browse guilds
;; - Browse channels
;; - View and send messages
;; - See real-time updates

;; 11. Mark a channel as read
(discord-mark-as-read
 my-channel-id
 "LAST_MESSAGE_ID"
 (lambda (_result)
   (message "Channel marked as read")))

;; 12. Get read state
(discord-get-read-state
 my-channel-id
 (lambda (result)
   (let ((rs (plist-get result :readState)))
     (message "Last read message: %s, mentions: %d"
              (plist-get rs :lastMessageId)
              (plist-get rs :mentionCount)))))

;; 13. Disconnect when done
(discord-disconnect)
;; => Disconnected from Discord daemon

;; ──────────────────────────────────────────────────────────────
;; Advanced: Create a custom message viewer

(defun my-discord-show-recent-messages (channel-id)
  "Show recent messages from CHANNEL-ID in a nice format."
  (interactive "sChannel ID: ")
  (discord-get-messages
   channel-id
   (lambda (result)
     (let ((messages (reverse (plist-get result :messages)))
           (buf (get-buffer-create "*Discord Messages*")))
       (with-current-buffer buf
         (erase-buffer)
         (insert (propertize "Recent Messages\n\n" 'face 'bold))
         (dolist (msg messages)
           (let* ((author (plist-get msg :author))
                  (username (plist-get author :username))
                  (content (plist-get msg :content))
                  (timestamp (plist-get msg :timestamp))
                  (time-str (format-time-string "%Y-%m-%d %H:%M"
                                               (date-to-time timestamp))))
             (insert (propertize time-str 'face 'shadow))
             (insert " ")
             (insert (propertize username 'face 'bold))
             (insert ": ")
             (insert content)
             (insert "\n\n")))
         (goto-char (point-min)))
       (pop-to-buffer buf)))
   50 nil))

;; Usage:
;; (my-discord-show-recent-messages "YOUR_CHANNEL_ID")

;; ──────────────────────────────────────────────────────────────
;; Advanced: Monitor a channel for keywords

(defvar my-discord-keyword-alerts nil
  "List of keywords to alert on.")

(setq my-discord-keyword-alerts '("bug" "urgent" "help" "deploy"))

(discord-on 'messageCreated
  (lambda (params)
    (let* ((msg (plist-get params :message))
           (content (downcase (plist-get msg :content)))
           (author (plist-get msg :author))
           (username (plist-get author :username)))
      (dolist (keyword my-discord-keyword-alerts)
        (when (string-match-p keyword content)
          (message "⚠️  ALERT: '%s' mentioned by %s: %s"
                   keyword username content))))))

EOF
