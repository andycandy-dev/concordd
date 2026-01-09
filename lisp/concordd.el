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
;; UI v2 Features:
;; - EWOC-based message display with incremental updates
;; - Full markdown rendering via markdown-view-mode
;; - Discord mention resolution
;; - Consult-based navigation (optional, requires consult package)
;;
;; Usage:
;;   (require 'concordd)
;;   (setq concordd-ui-implementation 'v2)  ; Use new UI
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

(defcustom concordd-discord-token nil
  "Discord bot token for concordd daemon.
If set, concordd will start and manage its own daemon process.
If nil, assumes an external daemon is already running."
  :type '(choice (const :tag "Use external daemon" nil)
                 (string :tag "Discord token"))
  :group 'concordd)

(defcustom concordd-socket-path 
  (expand-file-name "concordd/concordd.sock" user-emacs-directory)
  "Path to the concordd daemon Unix socket.
Used for both connecting to external daemons and managed daemons."
  :type 'string
  :group 'concordd)

(defcustom concordd-binary-path nil
  "Path to concordd binary.
Can be either:
- A local file path: \"/usr/local/bin/concordd\"
- A download URL: \"https://example.com/concordd-linux-amd64\"
- nil: Find in PATH using `executable-find'"
  :type '(choice (const :tag "Find in PATH" nil)
                 (file :tag "Local file path")
                 (string :tag "Download URL"))
  :group 'concordd)

(defcustom concordd-log-messages nil
  "Whether to log JSON-RPC messages for debugging."
  :type 'boolean
  :group 'concordd)

(defvar concordd-after-connect-hook nil
  "Hook run after successfully connecting to concordd daemon.")

(defvar concordd--process nil
  "Process object for managed concordd daemon.")

(defvar concordd--managing-daemon nil
  "Non-nil if this Emacs session is managing the daemon lifecycle.")

;;; Binary management

(defun concordd--binary-dir ()
  "Return the directory for concordd binary."
  (expand-file-name "concordd/bin" user-emacs-directory))

(defun concordd--binary-name ()
  "Return the concordd binary name for current platform."
  (if (eq system-type 'windows-nt) "concordd.exe" "concordd"))

(defun concordd--download-binary (url)
  "Download concordd binary from URL and return path."
  (let* ((binary-dir (concordd--binary-dir))
         (binary-path (expand-file-name (concordd--binary-name) binary-dir))
         (is-zip (string-suffix-p ".zip" url))
         (is-archive (or is-zip (string-suffix-p ".tar.gz" url))))
    (make-directory binary-dir t)
    (if is-archive
        (concordd--download-and-extract-archive url binary-dir binary-path is-zip)
      (concordd--download-direct-binary url binary-path))
    binary-path))

(defun concordd--download-and-extract-archive (url binary-dir binary-path is-zip)
  "Download archive from URL to BINARY-DIR, extract to BINARY-PATH.
IS-ZIP determines whether to use unzip or tar."
  (let ((archive-path (expand-file-name (if is-zip "concordd.zip" "concordd.tar.gz")
                                         binary-dir)))
    (message "Downloading concordd archive from %s..." url)
    (url-copy-file url archive-path t)
    (message "Extracting archive...")
    (let ((default-directory binary-dir))
      (if is-zip
          (call-process "unzip" nil nil nil "-o" archive-path)
        (call-process "tar" nil nil nil "xzf" archive-path)))
    (delete-file archive-path)
    (concordd--set-executable-if-unix binary-path)
    (message "Extracted concordd binary to %s" binary-path)))

(defun concordd--download-direct-binary (url binary-path)
  "Download binary directly from URL to BINARY-PATH."
  (message "Downloading concordd binary from %s..." url)
  (url-copy-file url binary-path t)
  (concordd--set-executable-if-unix binary-path)
  (message "Downloaded concordd binary to %s" binary-path))

(defun concordd--set-executable-if-unix (path)
  "Set executable permissions on PATH if not on Windows."
  (unless (eq system-type 'windows-nt)
    (set-file-modes path #o755)))

(defun concordd--ensure-binary ()
  "Ensure concordd binary exists.
Returns path to binary or signals error if not found."
  (cond
   ;; Local file path
   ((and concordd-binary-path
         (not (string-prefix-p "http" concordd-binary-path)))
    (if (file-exists-p concordd-binary-path)
        concordd-binary-path
      (error "Binary not found at: %s" concordd-binary-path)))
   
   ;; Download URL
   ((and concordd-binary-path
         (string-prefix-p "http" concordd-binary-path))
    (let ((cached-path (expand-file-name 
                        (if (eq system-type 'windows-nt)
                            "concordd/bin/concordd.exe"
                          "concordd/bin/concordd")
                        user-emacs-directory)))
      (if (file-exists-p cached-path)
          cached-path
        (concordd--download-binary concordd-binary-path))))
   
   ;; Find in PATH
   (t
    (or (executable-find "concordd")
        (error "Concordd binary not found in PATH. Set `concordd-binary-path' to a local path or download URL")))))

;;; Daemon lifecycle management

(defun concordd--start-daemon ()
  "Start concordd daemon process.
Returns non-nil if daemon was started successfully."
  (when concordd--process
    (error "Daemon process already running"))
  
  (unless concordd-discord-token
    (error "concordd-discord-token must be set to start managed daemon"))
  
  (let ((binary (concordd--ensure-binary)))
    (unless binary
      (error "Could not find or download concordd binary"))
    
    ;; Clean up existing socket
    (when (file-exists-p concordd-socket-path)
      (delete-file concordd-socket-path))
    
    (message "Starting concordd daemon...")
    (setq concordd--process
          (make-process
           :name "concordd"
           :buffer "*concordd*"
           :command (list binary 
                         "start"
                         "--token" concordd-discord-token
                         "--socket-path" concordd-socket-path)
           :connection-type 'pipe
           :sentinel #'concordd--process-sentinel))
    
    (setq concordd--managing-daemon t)
    (set-process-query-on-exit-flag concordd--process nil)
    
    ;; Wait for socket to be created
    (let ((max-wait 10)
          (waited 0))
      (while (and (< waited max-wait)
                  (not (file-exists-p concordd-socket-path)))
        (sleep-for 0.5)
        (setq waited (+ waited 0.5)))
      
      (if (file-exists-p concordd-socket-path)
          (progn
            (message "Concordd daemon started")
            t)
        (concordd--stop-daemon)
        (error "Daemon failed to create socket within %d seconds" max-wait)))))

(defun concordd--stop-daemon ()
  "Stop managed concordd daemon process."
  (when concordd--process
    (when (process-live-p concordd--process)
      (kill-process concordd--process))
    (setq concordd--process nil
          concordd--managing-daemon nil)
    (when (file-exists-p concordd-socket-path)
      (ignore-errors (delete-file concordd-socket-path)))
    (message "Concordd daemon stopped")))

(defun concordd--process-sentinel (process event)
  "Sentinel for concordd daemon PROCESS.
EVENT describes the process state change."
  (unless (process-live-p process)
    (message "Concordd daemon exited: %s" (string-trim event))
    (setq concordd--process nil
          concordd--managing-daemon nil)))

;;; Connection management

;;;###autoload
(defun concordd-connect (&optional socket-path)
  "Connect to the concordd daemon.
If `concordd-discord-token' is set and no external daemon is found,
automatically starts and manages a daemon process.
Optional SOCKET-PATH overrides `concordd-socket-path'."
  (interactive)
  (let ((path (or socket-path concordd-socket-path)))
    ;; If token is set and socket doesn't exist, start daemon
    (when (and concordd-discord-token
               (not (file-exists-p path))
               (not concordd--managing-daemon))
      (concordd--start-daemon))
    
    ;; Connect to daemon (external or managed)
    (concordd-ipc-connect path)
    
    ;; Test connection with ping
    (concordd-ping
     (lambda (result)
       (message "Concordd daemon ready: %s" (plist-get result :status))
       (run-hooks 'concordd-after-connect-hook)))))

(defun concordd-disconnect ()
  "Disconnect from the concordd daemon.
If managing the daemon, also stops it."
  (interactive)
  (concordd-ipc-disconnect)
  (when concordd--managing-daemon
    (concordd--stop-daemon)))

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

(defun concordd-get-current-user (callback)
  "Get current user ID.
CALLBACK is called with the result containing :id."
  (concordd-ipc-send-request "getCurrentUser" nil callback))

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

(defun concordd-list-dms (callback)
  "List all direct message channels.
CALLBACK is called with a list of DM channel objects."
  (concordd-ipc-send-request "listDMs" nil callback))

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
     ;; Use consult-based navigation if available
     (if (require 'concordd-consult nil t)
         (consult-concordd-browse)
       ;; Fallback to simple browser
       (require 'concordd-ui-v2)
       (concordd-ui-v2-browser)))
    (_
     (user-error "Invalid concordd-ui-implementation: %s" concordd-ui-implementation))))

(defun concordd-open-dm ()
  "Open a direct message channel."
  (interactive)
  (unless (concordd-connected-p)
    (user-error "Not connected to Discord. Run M-x concordd-connect"))
  
  (concordd-list-dms
   (lambda (result)
     (let* ((channels (plist-get result :channels))
            (choices (mapcar (lambda (ch)
                              (cons (plist-get ch :name)
                                    (plist-get ch :id)))
                            channels))
            (selected (completing-read "Open DM: " choices nil t)))
       (when selected
         (let ((channel-id (cdr (assoc selected choices))))
           (pcase concordd-ui-implementation
             ('v2
              (require 'concordd-ui-v2)
              (concordd-ui-v2-open-channel channel-id selected nil))
             ('v1
              (require 'concordd-ui)
              (concordd-get-messages 
               channel-id 
               (lambda (result)
                 (concordd-ui-show-channel 
                  selected 
                  (plist-get result :messages)))
               50 
               nil))
             (_ (user-error "Invalid concordd-ui-implementation: %s" 
                           concordd-ui-implementation)))))))))

;;; Cleanup

(defun concordd--cleanup ()
  "Clean up concordd resources on Emacs exit."
  (when concordd--managing-daemon
    (concordd--stop-daemon)))

(add-hook 'kill-emacs-hook #'concordd--cleanup)

(provide 'concordd)

;;; concordd.el ends here
