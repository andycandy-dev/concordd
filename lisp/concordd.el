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

(defcustom concordd-ui-implementation 'v2
  "Which UI implementation to use.
v1 - Original UI with full buffer regeneration
v2 - New EWOC-based UI with incremental updates (recommended)"
  :type '(choice (const :tag "Original (v1)" v1)
                 (const :tag "EWOC-based (v2)" v2))
  :group 'concordd)

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

(defun concordd-list-forum-channels (guild-id callback)
  "List forum channels in GUILD-ID.
CALLBACK is called with a list of forum channel objects (type 15)."
  (concordd-list-channels guild-id
    (lambda (result)
      (let* ((channels (plist-get result :channels))
             (forum-channels (seq-filter 
                             (lambda (ch) (= (plist-get ch :type) 15))
                             channels)))
        (funcall callback (list :channels forum-channels))))))

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

(defun concordd-request-guild-members (guild-id user-ids callback)
  "Request guild members for GUILD-ID and USER-IDS via gateway.
CALLBACK is called when the request is sent (not when members arrive)."
  (concordd-ipc-send-request
   "requestGuildMembers"
   `(:guildId ,guild-id :userIds ,(vconcat user-ids))
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

;;; Thread/Forum methods

(defun concordd-list-threads (channel-id callback)
  "List threads in CHANNEL-ID.
CALLBACK is called with the result containing :threads list."
  (concordd-ipc-send-request
   "listThreads"
   `(:channelId ,channel-id)
   callback))

(defun concordd-create-thread (channel-id name callback &optional message-id auto-archive-duration)
  "Create a thread in CHANNEL-ID with NAME.
CALLBACK is called with the thread object.
Optional MESSAGE-ID creates a thread from that message.
Optional AUTO-ARCHIVE-DURATION is duration in minutes (60, 1440, 4320, 10080)."
  (let ((params `(:channelId ,channel-id :name ,name)))
    (when message-id
      (setq params (plist-put params :messageId message-id)))
    (when auto-archive-duration
      (setq params (plist-put params :autoArchiveDuration auto-archive-duration)))
    (concordd-ipc-send-request "createThread" params callback)))

(defun concordd-create-forum-post (channel-id name content callback &optional tags)
  "Create a forum post in CHANNEL-ID with NAME and CONTENT.
CALLBACK is called with result containing :thread and :message.
Optional TAGS is a list of tag ID strings."
  (let ((params `(:channelId ,channel-id :name ,name :content ,content)))
    (when tags
      (setq params (plist-put params :tags (vconcat tags))))
    (concordd-ipc-send-request "createForumPost" params callback)))

(defun concordd-join-thread (thread-id &optional callback)
  "Join THREAD-ID.
Optional CALLBACK is called on completion."
  (concordd-ipc-send-request
   "joinThread"
   `(:threadId ,thread-id)
   (or callback (lambda (_result) (message "Joined thread")))))

(defun concordd-leave-thread (thread-id &optional callback)
  "Leave THREAD-ID.
Optional CALLBACK is called on completion."
  (concordd-ipc-send-request
   "leaveThread"
   `(:threadId ,thread-id)
   (or callback (lambda (_result) (message "Left thread")))))

(defun concordd-archive-thread (thread-id &optional callback)
  "Archive THREAD-ID.
Optional CALLBACK is called on completion."
  (concordd-ipc-send-request
   "archiveThread"
   `(:threadId ,thread-id)
   (or callback (lambda (_result) (message "Thread archived")))))

(defun concordd-get-forum-tags (channel-id callback)
  "Get available forum tags for CHANNEL-ID.
CALLBACK is called with result containing :tags list."
  (concordd-ipc-send-request
   "getForumTags"
   `(:channelId ,channel-id)
   callback))

;;; UI entry point

;;;###autoload
(defun concordd-browse ()
  "Open Concordd browser interface."
  (interactive)
  (unless (concordd-connected-p)
    (concordd-connect))
  
  (pcase concordd-ui-implementation
    ('v1
     ;; Use original UI
     (concordd-list-guilds
      (lambda (result)
        (concordd-ui-show-guild-list (plist-get result :guilds)))))
    ('v2
     ;; Use new EWOC-based UI
     (require 'concordd-ui-v2)
     (concordd-ui-v2-browser))
    (_
     (user-error "Invalid concordd-ui-implementation: %s" concordd-ui-implementation))))

(provide 'concordd)

;;; concordd.el ends here
