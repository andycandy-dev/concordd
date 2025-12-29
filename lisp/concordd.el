;;; concordd.el --- Concordd IPC client for Emacs -*- lexical-binding: t; -*-

;; Copyright (C) 2025 Concordd Project
;; Author: Andrej Novikov
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1"))
;; Keywords: comm, discord
;; URL: https://github.com/andycandy-dev/concordd

;;; Commentary:

;; This package provides a Concordd client for Emacs that connects to
;; the concordd daemon via Unix domain socket using JSON-RPC 2.0.
;;
;; Features:
;; - List guilds and channels
;; - View message history
;; - Send messages and replies
;; - Real-time push notifications
;; - Mark channels as read
;;
;; Usage:
;;   (require 'concordd)
;;   (concordd-connect)
;;   (concordd-browse)

;;; Code:

(require 'concordd-ipc)
(require 'concordd-ui)

;;; Customization

(defgroup concordd nil
  "Concordd client for Emacs."
  :group 'comm
  :prefix "concordd-")

(defcustom concordd-socket-path "/tmp/concordd.sock"
  "Path to the concordd daemon Unix socket."
  :type 'string
  :group 'concordd)

(defcustom concordd-log-messages nil
  "Whether to log JSON-RPC messages for debugging."
  :type 'boolean
  :group 'concordd)

;;; Connection management

;;;###autoload
(defun concordd-connect (&optional socket-path)
  "Connect to the concordd daemon.
Optional SOCKET-PATH overrides `concordd-socket-path'."
  (interactive)
  (let ((path (or socket-path concordd-socket-path)))
    (concordd-ipc-connect path)
    ;; Test connection with ping
    (concordd-ping
     (lambda (result)
       (message "Concordd daemon ready: %s" (plist-get result :status))))))

(defun concordd-disconnect ()
  "Disconnect from the concordd daemon."
  (interactive)
  (concordd-ipc-disconnect))

(defun concordd-connected-p ()
  "Return non-nil if connected to the daemon."
  (concordd-ipc-connected-p))

;;; Event handling

(defun concordd-on (event handler)
  "Register an event handler.
EVENT is the event name (symbol or string).
HANDLER is a function that takes a params plist."
  (concordd-ipc-on event handler))

(defun concordd-off (event &optional handler)
  "Unregister event handlers.
EVENT is the event name (symbol or string).
If HANDLER is nil, remove all handlers for EVENT.
Otherwise, remove only that HANDLER."
  (concordd-ipc-off event handler))

;;; API methods

(defun concordd-ping (&optional callback)
  "Ping the daemon.
CALLBACK is called with the result."
  (interactive)
  (concordd-ipc-send-request
   "ping"
   nil
   (or callback
       (lambda (result)
         (when (called-interactively-p 'interactive)
           (message "Pong! %s" (plist-get result :timestamp)))))))

(defun concordd-list-guilds (callback)
  "List all guilds.
CALLBACK is called with a list of guild objects."
  (interactive
   (list (lambda (result)
           (let ((guilds (plist-get result :guilds)))
             (message "Guilds: %s" 
                     (mapconcat (lambda (g) (plist-get g :name))
                               guilds ", "))))))
  (concordd-ipc-send-request "listGuilds" nil callback))

(defun concordd-list-channels (guild-id callback)
  "List all channels in GUILD-ID.
CALLBACK is called with a list of channel objects."
  (concordd-ipc-send-request
   "listChannels"
   `(:guildId ,guild-id)
   callback))

(defun concordd-get-messages (channel-id callback &optional limit before)
  "Get messages from CHANNEL-ID.
CALLBACK is called with a list of message objects.
Optional LIMIT specifies number of messages (default: 50).
Optional BEFORE is a message ID for pagination."
  (let ((params `(:channelId ,channel-id)))
    (when limit
      (setq params (plist-put params :limit limit)))
    (when before
      (setq params (plist-put params :before before)))
    (concordd-ipc-send-request "getMessages" params callback)))

(defun concordd-send-message (channel-id content callback)
  "Send a message to CHANNEL-ID with CONTENT.
CALLBACK is called with the sent message object."
  (concordd-ipc-send-request
   "sendMessage"
   `(:channelId ,channel-id :content ,content)
   callback))

(defun concordd-reply-to-message (channel-id message-id content callback)
  "Reply to MESSAGE-ID in CHANNEL-ID with CONTENT.
CALLBACK is called with the sent message object."
  (concordd-ipc-send-request
   "replyToMessage"
   `(:channelId ,channel-id :messageId ,message-id :content ,content)
   callback))

(defun concordd-mark-as-read (channel-id message-id &optional callback)
  "Mark CHANNEL-ID as read up to MESSAGE-ID.
Optional CALLBACK is called on completion."
  (concordd-ipc-send-request
   "markAsRead"
   `(:channelId ,channel-id :messageId ,message-id)
   (or callback (lambda (_result) nil))))

(defun concordd-get-read-state (channel-id callback)
  "Get read state for CHANNEL-ID.
CALLBACK is called with the read state object."
  (concordd-ipc-send-request
   "getReadState"
   `(:channelId ,channel-id)
   callback))

(defun concordd-get-guild-members (guild-id callback)
  "Get members for GUILD-ID.
CALLBACK is called with a list of member objects."
  (concordd-ipc-send-request
   "getGuildMembers"
   `(:guildId ,guild-id)
   callback))

(defun concordd-get-guild-roles (guild-id callback)
  "Get roles for GUILD-ID.
CALLBACK is called with a list of role objects."
  (concordd-ipc-send-request
   "getGuildRoles"
   `(:guildId ,guild-id)
   callback))

(defun concordd-edit-message (channel-id message-id content callback)
  "Edit MESSAGE-ID in CHANNEL-ID with new CONTENT.
CALLBACK is called with the edited message object."
  (concordd-ipc-send-request
   "editMessage"
   `(:channelId ,channel-id :messageId ,message-id :content ,content)
   callback))

(defun concordd-delete-message (channel-id message-id &optional callback)
  "Delete MESSAGE-ID in CHANNEL-ID.
Optional CALLBACK is called on completion."
  (concordd-ipc-send-request
   "deleteMessage"
   `(:channelId ,channel-id :messageId ,message-id)
   (or callback (lambda (_result) (message "Message deleted")))))

;;; UI entry point

;;;###autoload
(defun concordd-browse ()
  "Open Concordd browser interface."
  (interactive)
  (unless (concordd-connected-p)
    (concordd-connect))
  
  ;; Fetch guilds
  (concordd-list-guilds
   (lambda (result)
     (concordd-ui-show-guild-list (plist-get result :guilds)))))

(provide 'concordd)

;;; concordd.el ends here
