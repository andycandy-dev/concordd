;;; discord.el --- Discord IPC client for Emacs -*- lexical-binding: t; -*-

;; Copyright (C) 2025 Discordo Project
;; Author: Discordo Project
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1"))
;; Keywords: comm, discord
;; URL: https://github.com/ayn2op/discordo

;;; Commentary:

;; This package provides a Discord client for Emacs that connects to
;; the discordo-daemon via Unix domain socket using JSON-RPC 2.0.
;;
;; Features:
;; - List guilds and channels
;; - View message history
;; - Send messages and replies
;; - Real-time push notifications
;; - Mark channels as read
;;
;; Usage:
;;   (require 'discord)
;;   (discord-connect)
;;   (discord-list-guilds)

;;; Code:

(require 'json)
(require 'cl-lib)

;;; Customization

(defgroup discord nil
  "Discord client for Emacs."
  :group 'comm
  :prefix "discord-")

(defcustom discord-socket-path "/tmp/concordd.sock"
  "Path to the discordo-daemon Unix socket."
  :type 'string
  :group 'discord)

(defcustom discord-log-messages nil
  "Whether to log JSON-RPC messages for debugging."
  :type 'boolean
  :group 'discord)

;;; Internal variables

(defvar discord--connection nil
  "Network process for the daemon connection.")

(defvar discord--request-id 0
  "Counter for JSON-RPC request IDs.")

(defvar discord--pending-requests (make-hash-table :test 'equal)
  "Hash table of pending requests awaiting responses.
Keys are request IDs, values are callback functions.")

(defvar discord--event-handlers (make-hash-table :test 'equal)
  "Hash table of event handlers for push notifications.
Keys are method names (strings), values are lists of callback functions.")

(defvar discord--buffer nil
  "Buffer for accumulating incoming data.")

(defvar discord--current-user-id nil
  "The current user's Discord ID.")

;;; Connection management

(defun discord-connect (&optional socket-path)
  "Connect to the discordo-daemon.
Optional SOCKET-PATH overrides `discord-socket-path'."
  (interactive)
  (when discord--connection
    (error "Already connected to Discord daemon"))
  
  (let ((path (or socket-path discord-socket-path)))
    (unless (file-exists-p path)
      (error "Socket not found: %s. Is discordo-daemon running?" path))
    
    (setq discord--connection
          (make-network-process
           :name "discord-daemon"
           :remote path
           :coding 'utf-8
           :filter #'discord--filter
           :sentinel #'discord--sentinel))
    
    (setq discord--buffer "")
    (message "Connected to Discord daemon at %s" path)
    
    ;; Test connection with ping
    (discord-ping
     (lambda (result)
       (message "Discord daemon ready: %s" (plist-get result :status))))))

(defun discord-disconnect ()
  "Disconnect from the discordo-daemon."
  (interactive)
  (when discord--connection
    (delete-process discord--connection)
    (setq discord--connection nil)
    (setq discord--buffer "")
    (clrhash discord--pending-requests)
    (message "Disconnected from Discord daemon")))

(defun discord-connected-p ()
  "Return non-nil if connected to the daemon."
  (and discord--connection
       (process-live-p discord--connection)))

;;; JSON-RPC implementation

(defun discord--next-id ()
  "Generate next request ID."
  (cl-incf discord--request-id))

(defun discord--send-request (method params callback)
  "Send a JSON-RPC request to the daemon.
METHOD is the RPC method name.
PARAMS is a plist of parameters.
CALLBACK is called with the result on success, or nil on error."
  (unless (discord-connected-p)
    (error "Not connected to Discord daemon"))
  
  (let* ((id (discord--next-id))
         (request `((jsonrpc . "2.0")
                   (id . ,id)
                   (method . ,method)
                   (params . ,params)))
         (json (concat (json-encode request) "\n")))
    
    (when discord-log-messages
      (message "→ %s" json))
    
    (puthash id callback discord--pending-requests)
    (process-send-string discord--connection json)))

(defun discord--filter (proc string)
  "Process filter for incoming data from daemon.
PROC is the network process.
STRING is the incoming data."
  (setq discord--buffer (concat discord--buffer string))
  
  ;; Process complete lines (messages end with \n)
  (while (string-match "\n" discord--buffer)
    (let* ((line-end (match-beginning 0))
           (line (substring discord--buffer 0 line-end)))
      (setq discord--buffer (substring discord--buffer (1+ line-end)))
      (discord--handle-message line))))

(defun discord--handle-message (line)
  "Handle a complete JSON-RPC message from the daemon.
LINE is the JSON string."
  (when discord-log-messages
    (message "← %s" line))
  
  (condition-case err
      (let ((msg (json-parse-string line :object-type 'plist :array-type 'list)))
        (if (plist-get msg :id)
            ;; Response
            (discord--handle-response msg)
          ;; Notification
          (discord--handle-notification msg)))
    (error
     (message "Error parsing JSON-RPC message: %s" err))))

(defun discord--handle-response (msg)
  "Handle a JSON-RPC response.
MSG is the parsed response plist."
  (let* ((id (plist-get msg :id))
         (callback (gethash id discord--pending-requests)))
    (remhash id discord--pending-requests)
    
    (when callback
      (if (plist-get msg :error)
          (let ((error-obj (plist-get msg :error)))
            (message "Discord RPC error: %s" (plist-get error-obj :message))
            (funcall callback nil))
        (funcall callback (plist-get msg :result))))))

(defun discord--handle-notification (msg)
  "Handle a JSON-RPC notification (push event).
MSG is the parsed notification plist."
  (let* ((method (plist-get msg :method))
         (params (plist-get msg :params))
         (handlers (gethash method discord--event-handlers)))
    
    (when discord-log-messages
      (message "Event: %s" method))
    
    (dolist (handler handlers)
      (condition-case err
          (funcall handler params)
        (error
         (message "Error in event handler for %s: %s" method err))))))

(defun discord--sentinel (proc event)
  "Process sentinel for connection status.
PROC is the network process.
EVENT describes the status change."
  (unless (process-live-p proc)
    (message "Disconnected from Discord daemon: %s" (string-trim event))
    (setq discord--connection nil)))

;;; Event handling

(defun discord-on (event handler)
  "Register an event handler.
EVENT is the event name (symbol or string).
HANDLER is a function that takes a params plist."
  (let* ((event-name (if (symbolp event) (symbol-name event) event))
         (handlers (gethash event-name discord--event-handlers)))
    (puthash event-name (cons handler handlers) discord--event-handlers)))

(defun discord-off (event &optional handler)
  "Unregister event handlers.
EVENT is the event name (symbol or string).
If HANDLER is nil, remove all handlers for EVENT.
Otherwise, remove only that HANDLER."
  (let ((event-name (if (symbolp event) (symbol-name event) event)))
    (if handler
        (let ((handlers (gethash event-name discord--event-handlers)))
          (puthash event-name (delq handler handlers) discord--event-handlers))
      (remhash event-name discord--event-handlers))))

;;; API methods

(defun discord-ping (&optional callback)
  "Ping the daemon.
CALLBACK is called with the result."
  (interactive)
  (discord--send-request
   "ping"
   nil
   (or callback
       (lambda (result)
         (when (called-interactively-p 'interactive)
           (message "Pong! %s" (plist-get result :timestamp)))))))

(defun discord-list-guilds (callback)
  "List all guilds.
CALLBACK is called with a list of guild objects."
  (interactive
   (list (lambda (result)
           (let ((guilds (plist-get result :guilds)))
             (message "Guilds: %s" 
                     (mapconcat (lambda (g) (plist-get g :name))
                               guilds ", "))))))
  (discord--send-request "listGuilds" nil callback))

(defun discord-list-channels (guild-id callback)
  "List all channels in GUILD-ID.
CALLBACK is called with a list of channel objects."
  (discord--send-request
   "listChannels"
   `(:guildId ,guild-id)
   callback))

(defun discord-get-messages (channel-id callback &optional limit before)
  "Get messages from CHANNEL-ID.
CALLBACK is called with a list of message objects.
Optional LIMIT specifies number of messages (default: 50).
Optional BEFORE is a message ID for pagination."
  (let ((params `(:channelId ,channel-id)))
    (when limit
      (setq params (plist-put params :limit limit)))
    (when before
      (setq params (plist-put params :before before)))
    (discord--send-request "getMessages" params callback)))

(defun discord-send-message (channel-id content callback)
  "Send a message to CHANNEL-ID with CONTENT.
CALLBACK is called with the sent message object."
  (discord--send-request
   "sendMessage"
   `(:channelId ,channel-id :content ,content)
   callback))

(defun discord-reply-to-message (channel-id message-id content callback)
  "Reply to MESSAGE-ID in CHANNEL-ID with CONTENT.
CALLBACK is called with the sent message object."
  (discord--send-request
   "replyToMessage"
   `(:channelId ,channel-id :messageId ,message-id :content ,content)
   callback))

(defun discord-mark-as-read (channel-id message-id &optional callback)
  "Mark CHANNEL-ID as read up to MESSAGE-ID.
Optional CALLBACK is called on completion."
  (discord--send-request
   "markAsRead"
   `(:channelId ,channel-id :messageId ,message-id)
   (or callback (lambda (_result) nil))))

(defun discord-get-read-state (channel-id callback)
  "Get read state for CHANNEL-ID.
CALLBACK is called with the read state object."
  (discord--send-request
   "getReadState"
   `(:channelId ,channel-id)
   callback))

(defun discord-get-guild-members (guild-id callback)
  "Get members for GUILD-ID.
CALLBACK is called with a list of member objects."
  (discord--send-request
   "getGuildMembers"
   `(:guildId ,guild-id)
   callback))

(defun discord-get-guild-roles (guild-id callback)
  "Get roles for GUILD-ID.
CALLBACK is called with a list of role objects."
  (discord--send-request
   "getGuildRoles"
   `(:guildId ,guild-id)
   callback))

(defun discord-edit-message (channel-id message-id content callback)
  "Edit MESSAGE-ID in CHANNEL-ID with new CONTENT.
CALLBACK is called with the edited message object."
  (discord--send-request
   "editMessage"
   `(:channelId ,channel-id :messageId ,message-id :content ,content)
   callback))

(defun discord-delete-message (channel-id message-id &optional callback)
  "Delete MESSAGE-ID in CHANNEL-ID.
Optional CALLBACK is called on completion."
  (discord--send-request
   "deleteMessage"
   `(:channelId ,channel-id :messageId ,message-id)
   (or callback (lambda (_result) (message "Message deleted")))))

;;; Simple UI

(defvar discord-guilds nil
  "Cached list of guilds.")

(defvar discord-current-guild nil
  "Currently selected guild ID.")

(defvar discord-current-channel nil
  "Currently selected channel ID.")

(defvar discord-guild-members nil
  "Hash table of guild ID -> members list.")

(defvar discord-guild-roles nil
  "Hash table of guild ID -> roles list.")

(setq discord-guild-members (make-hash-table :test 'equal))
(setq discord-guild-roles (make-hash-table :test 'equal))

(defun discord-browse ()
  "Open Discord browser interface."
  (interactive)
  (unless (discord-connected-p)
    (discord-connect))
  
  ;; Fetch guilds
  (discord-list-guilds
   (lambda (result)
     (setq discord-guilds (plist-get result :guilds))
     (discord--show-guild-list))))

(defun discord--show-guild-list ()
  "Show list of guilds in a buffer."
  (let ((buf (get-buffer-create "*Discord Guilds*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (discord-guild-list-mode)
        (insert (propertize "Discord Guilds\n\n" 'face 'bold))
        (dolist (guild discord-guilds)
          (let ((name (plist-get guild :name))
                (id (plist-get guild :id)))
            (insert-button name
                          'action (lambda (_btn) (discord--select-guild id))
                          'follow-link t)
            (insert "\n"))))
      (goto-char (point-min)))
    (pop-to-buffer buf)))

(defun discord--select-guild (guild-id)
  "Select and show channels for GUILD-ID."
  (setq discord-current-guild guild-id)
  (discord-list-channels
   guild-id
   (lambda (result)
     (discord--show-channel-list (plist-get result :channels)))))

(defun discord--show-channel-list (channels)
  "Show list of CHANNELS in a buffer."
  (let ((buf (get-buffer-create "*Discord Channels*"))
        (guild-name (cl-loop for g in discord-guilds
                            when (string= (plist-get g :id) discord-current-guild)
                            return (plist-get g :name))))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (discord-channel-list-mode)
        (insert (propertize (format "Channels in %s\n\n" guild-name) 'face 'bold))
        (dolist (channel channels)
          (let* ((name (plist-get channel :name))
                 (id (plist-get channel :id))
                 (unread (plist-get channel :unread))
                 (mentioned (plist-get channel :mentioned)))
            (when (= (plist-get channel :type) 0) ; Text channel
              (when mentioned
                (insert "@ "))
              (when unread
                (insert "● "))
              (insert-button (format "#%s" name)
                            'action (lambda (_btn) (discord--open-channel id name))
                            'follow-link t)
              (insert "\n")))))
      (goto-char (point-min)))
    (pop-to-buffer buf)))

(defun discord--open-channel (channel-id channel-name)
  "Open messages for CHANNEL-ID with CHANNEL-NAME."
  (setq discord-current-channel channel-id)
  (let ((buf (get-buffer-create (format "*Discord: #%s*" channel-name))))
    (with-current-buffer buf
      (discord-channel-mode)
      (setq-local discord-channel-id channel-id)
      (setq-local discord-channel-name channel-name)
      (setq-local discord-channel-guild-id discord-current-guild)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize (format "Channel: #%s\n\n" channel-name) 'face 'bold))
        (insert "Loading messages...\n\n")
        (insert (propertize "Keybindings: n=new message, p=load more, gr=reload, q=quit\n" 'face 'shadow))))
    (pop-to-buffer buf)
    
    ;; Load guild metadata (members and roles) for mention rendering
    (when discord-current-guild
      (discord--load-guild-metadata discord-current-guild))
    
    ;; Load messages
    (discord--load-channel-messages channel-id)))

(defun discord--load-guild-metadata (guild-id)
  "Load members and roles for GUILD-ID into cache."
  (unless (gethash guild-id discord-guild-members)
    (discord-get-guild-members
     guild-id
     (lambda (result)
       (puthash guild-id (plist-get result :members) discord-guild-members))))
  
  (unless (gethash guild-id discord-guild-roles)
    (discord-get-guild-roles
     guild-id
     (lambda (result)
       (puthash guild-id (plist-get result :roles) discord-guild-roles)))))

(defun discord--load-channel-messages (channel-id)
  "Load messages for CHANNEL-ID."
  (discord-get-messages
   channel-id
   (lambda (result)
     (let ((messages (reverse (plist-get result :messages))))
       (discord--display-messages channel-id messages nil)))
   50 nil))

(defun discord-load-more-messages ()
  "Load older messages in current channel."
  (interactive)
  (unless discord-channel-id
    (error "Not in a Discord channel buffer"))
  
  (when discord-loading-messages
    (message "Already loading messages...")
    (cl-return-from discord-load-more-messages))
  
  (unless discord-oldest-message-id
    (message "No older messages to load")
    (cl-return-from discord-load-more-messages))
  
  (setq discord-loading-messages t)
  (message "Loading older messages...")
  
  (discord-get-messages
   discord-channel-id
   (lambda (result)
     (setq discord-loading-messages nil)
     (let ((messages (reverse (plist-get result :messages))))
       (if (null messages)
           (message "No more messages")
         (discord--prepend-messages discord-channel-id messages)
         (message "Loaded %d messages" (length messages)))))
   50
   discord-oldest-message-id))

(defun discord--display-messages (channel-id messages &optional keep-position)
  "Display MESSAGES for CHANNEL-ID in current buffer.
If KEEP-POSITION is non-nil, try to maintain cursor position."
  (let ((buf (cl-find-if
              (lambda (b)
                (with-current-buffer b
                  (and (eq major-mode 'discord-channel-mode)
                       (string= discord-channel-id channel-id))))
              (buffer-list))))
    (when buf
      (with-current-buffer buf
        (let ((inhibit-read-only t)
              (old-point (when keep-position (point))))
          (erase-buffer)
          (insert (propertize (format "Channel: #%s\n\n" discord-channel-name) 'face 'bold))
          
          ;; Track oldest message for pagination
          (when messages
            (setq discord-oldest-message-id (plist-get (car messages) :id)))
          
          ;; Insert messages
          (dolist (msg messages)
            (discord--insert-message msg))
          
          ;; Add help text
          (goto-char (point-max))
          (insert "\n" (propertize "──────────────────────\n" 'face 'bold))
          (insert (propertize "Keybindings: n=new message, p=load more, gr=reload, q=quit\n" 'face 'shadow))
          
          ;; Restore or move to end
          (if (and keep-position old-point)
              (goto-char (min old-point (point-max)))
            (goto-char (point-max))))))))

(defun discord--prepend-messages (channel-id messages)
  "Prepend MESSAGES to CHANNEL-ID buffer (for pagination)."
  (let ((buf (cl-find-if
              (lambda (b)
                (with-current-buffer b
                  (and (eq major-mode 'discord-channel-mode)
                       (string= discord-channel-id channel-id))))
              (buffer-list))))
    (when buf
      (with-current-buffer buf
        (let ((inhibit-read-only t))
          (save-excursion
            ;; Find where messages start (after header)
            (goto-char (point-min))
            (forward-line 2) ; Skip "Channel: #name" and blank line
            
            ;; Update oldest message ID
            (when messages
              (setq discord-oldest-message-id (plist-get (car messages) :id)))
            
            ;; Insert older messages at the top
            (dolist (msg messages)
              (discord--insert-message msg))))))))

(defun discord--insert-message (msg)
  "Insert a single message MSG into current buffer."
  (let* ((author (plist-get msg :author))
         (username (plist-get author :username))
         (content (plist-get msg :content))
         (timestamp (plist-get msg :timestamp))
         (time-str (format-time-string "%H:%M" (date-to-time timestamp)))
         ;; Use buffer-local guild-id instead of message's guild-id
         (guild-id discord-channel-guild-id)
         (message-id (plist-get msg :id))
         (author-id (plist-get author :id))
         (start-pos (point)))
    
    (insert (propertize (format "[%s] " time-str) 'face 'shadow))
    (insert (propertize username 'face 'bold))
    (insert ": ")
    
    ;; Render content with mentions resolved
    (discord--insert-content-with-mentions content guild-id)
    (insert "\n")
    
    ;; Add text properties to the entire message line for easy lookup
    (put-text-property start-pos (point) 'discord-message-id message-id)
    (put-text-property start-pos (point) 'discord-author-id author-id)
    (put-text-property start-pos (point) 'discord-message-content content)))

(defun discord--insert-content-with-mentions (content guild-id)
  "Insert CONTENT with mentions resolved using GUILD-ID cache."
  (let ((pos 0)
        (members (when guild-id (gethash guild-id discord-guild-members)))
        (roles (when guild-id (gethash guild-id discord-guild-roles))))
    
    (while (string-match "<@\\(&?\\)\\([0-9]+\\)>" content pos)
      ;; Insert text before mention
      (insert (substring content pos (match-beginning 0)))
      
      (let* ((is-role (string= (match-string 1 content) "&"))
             (id (match-string 2 content))
             (mention-text (match-string 0 content)))
        
        (if is-role
            ;; Role mention
            (let ((role (cl-find-if
                        (lambda (r) (string= (plist-get r :id) id))
                        roles)))
              (if role
                  (insert (propertize (format "@%s" (plist-get role :name))
                                    'face '(:foreground "cyan" :weight bold)))
                (insert (propertize mention-text 'face 'shadow))))
          
          ;; User mention
          (let ((member (cl-find-if
                        (lambda (m)
                          (string= (plist-get (plist-get m :user) :id) id))
                        members)))
            (if member
                (let* ((user (plist-get member :user))
                       (nick (plist-get member :nick))
                       (display-name (or nick (plist-get user :username))))
                  (insert (propertize (format "@%s" display-name)
                                    'face '(:foreground "yellow" :weight bold))))
              (insert (propertize mention-text 'face 'shadow))))))
      
      (setq pos (match-end 0)))
    
    ;; Insert remaining text
    (insert (substring content pos))))

;;; Major modes

(defvar discord-guild-list-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "q") #'quit-window)
    (define-key map (kbd "g") #'discord-browse)
    map)
  "Keymap for `discord-guild-list-mode'.")

(define-derived-mode discord-guild-list-mode special-mode "Discord-Guilds"
  "Major mode for browsing Discord guilds."
  (setq buffer-read-only t))

(defvar discord-channel-list-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "q") #'quit-window)
    (define-key map (kbd "g") #'discord-browse)
    map)
  "Keymap for `discord-channel-list-mode'.")

(define-derived-mode discord-channel-list-mode special-mode "Discord-Channels"
  "Major mode for browsing Discord channels."
  (setq buffer-read-only t))

(defvar-local discord-channel-id nil
  "Channel ID for current Discord channel buffer.")

(defvar-local discord-channel-name nil
  "Channel name for current Discord channel buffer.")

(defvar-local discord-channel-guild-id nil
  "Guild ID for current Discord channel buffer.")

(defvar-local discord-oldest-message-id nil
  "ID of the oldest message currently loaded in buffer.")

(defvar-local discord-loading-messages nil
  "Non-nil if currently loading more messages.")

(defvar discord-channel-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-n") #'discord-compose-message)
    (define-key map (kbd "C-c C-r") #'discord-reply-to-message-at-point)
    (define-key map (kbd "C-c C-l") #'discord-channel-reload)
    (define-key map (kbd "C-c C-p") #'discord-load-more-messages)
    (define-key map (kbd "C-c C-e") #'discord-edit-message-at-point)
    (define-key map (kbd "C-c C-d") #'discord-delete-message-at-point)
    (define-key map (kbd "q") #'quit-window)
    ;; Evil-friendly bindings (will work in normal state)
    (define-key map (kbd "n") #'discord-compose-message)
    (define-key map (kbd "R") #'discord-reply-to-message-at-point)
    (define-key map (kbd "gr") #'discord-channel-reload)
    (define-key map (kbd "gp") #'discord-load-more-messages)
    (define-key map (kbd "p") #'discord-load-more-messages)
    (define-key map (kbd "e") #'discord-edit-message-at-point)
    (define-key map (kbd "dd") #'discord-delete-message-at-point)
    map)
  "Keymap for `discord-channel-mode'.")

(define-derived-mode discord-channel-mode special-mode "Discord-Channel"
  "Major mode for Discord channel messages.

Key bindings:
\\{discord-channel-mode-map}

Evil-friendly bindings:
  n   - Compose new message
  R   - Reply to message at point
  e   - Edit message at point (own messages only)
  dd  - Delete message at point (own messages only)
  p   - Load more (older) messages
  gr  - Reload messages
  q   - Quit window

Standard bindings:
  C-c C-n - Compose new message
  C-c C-r - Reply to message
  C-c C-e - Edit message
  C-c C-d - Delete message
  C-c C-p - Load more messages
  C-c C-l - Reload messages"
  (setq buffer-read-only t)
  
  ;; Evil mode integration
  (when (and (boundp 'evil-mode) evil-mode)
    (evil-set-initial-state 'discord-channel-mode 'normal))
  
  ;; Register event handler for new messages
  (discord-on 'messageCreated
              (lambda (params)
                (discord--handle-message-created params))))

(defun discord-compose-message ()
  "Open a compose buffer to send a message to current channel."
  (interactive)
  (unless discord-channel-id
    (error "Not in a Discord channel buffer"))
  
  (let* ((channel-id discord-channel-id)
         (channel-name discord-channel-name)
         (compose-buf (get-buffer-create (format "*Discord Compose: #%s*" channel-name))))
    (pop-to-buffer compose-buf)
    (discord-compose-mode)
    (setq-local discord-channel-id channel-id)
    (setq-local discord-channel-name channel-name)
    (erase-buffer)
    (insert (propertize (format "Composing message for #%s\n" channel-name) 'face 'bold))
    (insert (propertize "Press C-c C-c to send, C-c C-k to cancel\n\n" 'face 'shadow))
    (insert (propertize "──────────────────────\n\n" 'face 'bold))
    (goto-char (point-max))))

(defun discord-reply-to-message-at-point ()
  "Reply to the message at point (not yet implemented)."
  (interactive)
  (message "Reply functionality not yet implemented"))

(defun discord-edit-message-at-point ()
  "Edit the message at point if it's your own message."
  (interactive)
  (unless discord-channel-id
    (error "Not in a Discord channel buffer"))
  
  (let* ((message-id (get-text-property (point) 'discord-message-id))
         (author-id (get-text-property (point) 'discord-author-id))
         (content (get-text-property (point) 'discord-message-content)))
    
    (unless message-id
      (error "No message at point"))
    
    ;; We need to get the current user ID to check ownership
    ;; For now, we'll just try to edit - the server will reject if not owned
    (let ((edit-buf (get-buffer-create (format "*Discord Edit: %s*" message-id))))
      (pop-to-buffer edit-buf)
      (discord-compose-mode)
      (setq-local discord-channel-id discord-channel-id)
      (setq-local discord-editing-message-id message-id)
      (erase-buffer)
      (insert (propertize "Editing message\n" 'face 'bold))
      (insert (propertize "Press C-c C-c to save, C-c C-k to cancel\n\n" 'face 'shadow))
      (insert (propertize "──────────────────────\n\n" 'face 'bold))
      (insert content)
      (goto-char (point-max)))))

(defun discord-delete-message-at-point ()
  "Delete the message at point if it's your own message."
  (interactive)
  (unless discord-channel-id
    (error "Not in a Discord channel buffer"))
  
  (let ((message-id (get-text-property (point) 'discord-message-id)))
    
    (unless message-id
      (error "No message at point"))
    
    (when (y-or-n-p "Delete this message? ")
      (discord-delete-message
       discord-channel-id
       message-id
       (lambda (_result)
         (message "Message deleted"))))))

(defun discord-channel-reload ()
  "Reload messages in current channel."
  (interactive)
  (when discord-channel-id
    (setq discord-oldest-message-id nil)
    (setq discord-loading-messages nil)
    (discord--load-channel-messages discord-channel-id)))

;;; Compose mode

(defvar-local discord-editing-message-id nil
  "Message ID being edited, if any.")

(defvar discord-compose-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'discord-compose-send)
    (define-key map (kbd "C-c C-k") #'discord-compose-cancel)
    map)
  "Keymap for `discord-compose-mode'.")

(define-derived-mode discord-compose-mode text-mode "Discord-Compose"
  "Major mode for composing Discord messages.

Key bindings:
\\{discord-compose-mode-map}

  C-c C-c - Send message
  C-c C-k - Cancel"
  (setq buffer-read-only nil)
  
  ;; Evil mode integration - start in insert state
  (when (and (boundp 'evil-mode) evil-mode)
    (evil-set-initial-state 'discord-compose-mode 'insert)
    (evil-insert-state)))

(defun discord-compose-send ()
  "Send the message from compose buffer."
  (interactive)
  (unless discord-channel-id
    (error "Not in a Discord compose buffer"))
  
  ;; Find the content after the separator
  (save-excursion
    (goto-char (point-min))
    (when (search-forward "──────────────────────\n\n" nil t)
      (let ((content (string-trim (buffer-substring (point) (point-max)))))
        (when (> (length content) 0)
          (if discord-editing-message-id
              ;; Editing existing message
              (discord-edit-message
               discord-channel-id
               discord-editing-message-id
               content
               (lambda (result)
                 (message "Message edited!")))
            ;; Sending new message
            (discord-send-message
             discord-channel-id
             content
             (lambda (result)
               (message "Message sent!"))))
          (kill-buffer (current-buffer)))))))

(defun discord-compose-cancel ()
  "Cancel composing and close the buffer."
  (interactive)
  (when (y-or-n-p "Discard message? ")
    (kill-buffer (current-buffer))))


(defun discord--handle-message-created (params)
  "Handle messageCreated event with PARAMS."
  (let* ((msg (plist-get params :message))
         (channel-id (plist-get msg :channelId)))
    ;; Update buffer if it exists and matches
    (dolist (buf (buffer-list))
      (with-current-buffer buf
        (when (and (eq major-mode 'discord-channel-mode)
                   (string= discord-channel-id channel-id))
          (let ((inhibit-read-only t))
            (save-excursion
              ;; Find the separator line and insert before it
              (goto-char (point-min))
              (if (search-forward "──────────────────────\n" nil t)
                  (progn
                    (forward-line -1)
                    (insert "\n")
                    (forward-line -1)
                    (discord--insert-message msg))
                ;; No separator yet, just append
                (goto-char (point-max))
                (insert "\n")
                (discord--insert-message msg)))))))))

;;; Provide

(provide 'discord)

;;; discord.el ends here
