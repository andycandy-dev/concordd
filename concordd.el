;;; concordd.el --- Concordd IPC client for Emacs -*- lexical-binding: t; -*-

;; Copyright (C) 2025 Concorddo Project
;; Author: Concorddo Project
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1"))
;; Keywords: comm, concordd
;; URL: https://github.com/ayn2op/concorddo

;;; Commentary:

;; This package provides a Concordd client for Emacs that connects to
;; the concorddo-daemon via Unix domain socket using JSON-RPC 2.0.
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
;;   (concordd-list-guilds)

;;; Code:

(require 'json)
(require 'cl-lib)

;;; Customization

(defgroup concordd nil
  "Concordd client for Emacs."
  :group 'comm
  :prefix "concordd-")

(defcustom concordd-socket-path "/tmp/concordd.sock"
  "Path to the concorddo-daemon Unix socket."
  :type 'string
  :group 'concordd)

(defcustom concordd-log-messages nil
  "Whether to log JSON-RPC messages for debugging."
  :type 'boolean
  :group 'concordd)

;;; Internal variables

(defvar concordd--connection nil
  "Network process for the daemon connection.")

(defvar concordd--request-id 0
  "Counter for JSON-RPC request IDs.")

(defvar concordd--pending-requests (make-hash-table :test 'equal)
  "Hash table of pending requests awaiting responses.
Keys are request IDs, values are callback functions.")

(defvar concordd--event-handlers (make-hash-table :test 'equal)
  "Hash table of event handlers for push notifications.
Keys are method names (strings), values are lists of callback functions.")

(defvar concordd--buffer nil
  "Buffer for accumulating incoming data.")

(defvar concordd--current-user-id nil
  "The current user's Concordd ID.")

;;; Connection management

;;;###autoload
(defun concordd-connect (&optional socket-path)
  "Connect to the concorddo-daemon.
Optional SOCKET-PATH overrides `concordd-socket-path'."
  (interactive)
  (when concordd--connection
    (error "Already connected to Concordd daemon"))
  
  (let ((path (or socket-path concordd-socket-path)))
    (unless (file-exists-p path)
      (error "Socket not found: %s. Is concorddo-daemon running?" path))
    
    (setq concordd--connection
          (make-network-process
           :name "concordd-daemon"
           :family 'local
           :remote path
           :coding 'utf-8
           :filter #'concordd--filter
           :sentinel #'concordd--sentinel))
    
    (setq concordd--buffer "")
    (message "Connected to Concordd daemon at %s" path)
    
    ;; Test connection with ping
    (concordd-ping
     (lambda (result)
       (message "Concordd daemon ready: %s" (plist-get result :status))))))

(defun concordd-disconnect ()
  "Disconnect from the concorddo-daemon."
  (interactive)
  (when concordd--connection
    (delete-process concordd--connection)
    (setq concordd--connection nil)
    (setq concordd--buffer "")
    (clrhash concordd--pending-requests)
    (message "Disconnected from Concordd daemon")))

(defun concordd-connected-p ()
  "Return non-nil if connected to the daemon."
  (and concordd--connection
       (process-live-p concordd--connection)))

;;; JSON-RPC implementation

(defun concordd--next-id ()
  "Generate next request ID."
  (cl-incf concordd--request-id))

(defun concordd--send-request (method params callback)
  "Send a JSON-RPC request to the daemon.
METHOD is the RPC method name.
PARAMS is a plist of parameters.
CALLBACK is called with the result on success, or nil on error."
  (unless (concordd-connected-p)
    (error "Not connected to Concordd daemon"))
  
  (let* ((id (concordd--next-id))
         (request `((jsonrpc . "2.0")
                   (id . ,id)
                   (method . ,method)
                   (params . ,params)))
         (json (concat (json-encode request) "\n")))
    
    (when concordd-log-messages
      (message "→ %s" json))
    
    (puthash id callback concordd--pending-requests)
    (process-send-string concordd--connection json)))

(defun concordd--filter (proc string)
  "Process filter for incoming data from daemon.
PROC is the network process.
STRING is the incoming data."
  (setq concordd--buffer (concat concordd--buffer string))
  
  ;; Process complete lines (messages end with \n)
  (while (string-match "\n" concordd--buffer)
    (let* ((line-end (match-beginning 0))
           (line (substring concordd--buffer 0 line-end)))
      (setq concordd--buffer (substring concordd--buffer (1+ line-end)))
      (concordd--handle-message line))))

(defun concordd--handle-message (line)
  "Handle a complete JSON-RPC message from the daemon.
LINE is the JSON string."
  (when concordd-log-messages
    (message "← %s" line))
  
  (condition-case err
      (let ((msg (json-parse-string line :object-type 'plist :array-type 'list)))
        (if (plist-get msg :id)
            ;; Response
            (concordd--handle-response msg)
          ;; Notification
          (concordd--handle-notification msg)))
    (error
     (message "Error parsing JSON-RPC message: %s" err))))

(defun concordd--handle-response (msg)
  "Handle a JSON-RPC response.
MSG is the parsed response plist."
  (let* ((id (plist-get msg :id))
         (callback (gethash id concordd--pending-requests)))
    (remhash id concordd--pending-requests)
    
    (when callback
      (if (plist-get msg :error)
          (let ((error-obj (plist-get msg :error)))
            (message "Concordd RPC error: %s" (plist-get error-obj :message))
            (funcall callback nil))
        (funcall callback (plist-get msg :result))))))

(defun concordd--handle-notification (msg)
  "Handle a JSON-RPC notification (push event).
MSG is the parsed notification plist."
  (let* ((method (plist-get msg :method))
         (params (plist-get msg :params))
         (handlers (gethash method concordd--event-handlers)))
    
    (when concordd-log-messages
      (message "Event: %s" method))
    
    (dolist (handler handlers)
      (condition-case err
          (funcall handler params)
        (error
         (message "Error in event handler for %s: %s" method err))))))

(defun concordd--sentinel (proc event)
  "Process sentinel for connection status.
PROC is the network process.
EVENT describes the status change."
  (unless (process-live-p proc)
    (message "Disconnected from Concordd daemon: %s" (string-trim event))
    (setq concordd--connection nil)))

;;; Event handling

(defun concordd-on (event handler)
  "Register an event handler.
EVENT is the event name (symbol or string).
HANDLER is a function that takes a params plist."
  (let* ((event-name (if (symbolp event) (symbol-name event) event))
         (handlers (gethash event-name concordd--event-handlers)))
    (puthash event-name (cons handler handlers) concordd--event-handlers)))

(defun concordd-off (event &optional handler)
  "Unregister event handlers.
EVENT is the event name (symbol or string).
If HANDLER is nil, remove all handlers for EVENT.
Otherwise, remove only that HANDLER."
  (let ((event-name (if (symbolp event) (symbol-name event) event)))
    (if handler
        (let ((handlers (gethash event-name concordd--event-handlers)))
          (puthash event-name (delq handler handlers) concordd--event-handlers))
      (remhash event-name concordd--event-handlers))))

;;; API methods

(defun concordd-ping (&optional callback)
  "Ping the daemon.
CALLBACK is called with the result."
  (interactive)
  (concordd--send-request
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
  (concordd--send-request "listGuilds" nil callback))

(defun concordd-list-channels (guild-id callback)
  "List all channels in GUILD-ID.
CALLBACK is called with a list of channel objects."
  (concordd--send-request
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
    (concordd--send-request "getMessages" params callback)))

(defun concordd-send-message (channel-id content callback)
  "Send a message to CHANNEL-ID with CONTENT.
CALLBACK is called with the sent message object."
  (concordd--send-request
   "sendMessage"
   `(:channelId ,channel-id :content ,content)
   callback))

(defun concordd-reply-to-message (channel-id message-id content callback)
  "Reply to MESSAGE-ID in CHANNEL-ID with CONTENT.
CALLBACK is called with the sent message object."
  (concordd--send-request
   "replyToMessage"
   `(:channelId ,channel-id :messageId ,message-id :content ,content)
   callback))

(defun concordd-mark-as-read (channel-id message-id &optional callback)
  "Mark CHANNEL-ID as read up to MESSAGE-ID.
Optional CALLBACK is called on completion."
  (concordd--send-request
   "markAsRead"
   `(:channelId ,channel-id :messageId ,message-id)
   (or callback (lambda (_result) nil))))

(defun concordd-get-read-state (channel-id callback)
  "Get read state for CHANNEL-ID.
CALLBACK is called with the read state object."
  (concordd--send-request
   "getReadState"
   `(:channelId ,channel-id)
   callback))

(defun concordd-get-guild-members (guild-id callback)
  "Get members for GUILD-ID.
CALLBACK is called with a list of member objects."
  (concordd--send-request
   "getGuildMembers"
   `(:guildId ,guild-id)
   callback))

(defun concordd-get-guild-roles (guild-id callback)
  "Get roles for GUILD-ID.
CALLBACK is called with a list of role objects."
  (concordd--send-request
   "getGuildRoles"
   `(:guildId ,guild-id)
   callback))

(defun concordd-edit-message (channel-id message-id content callback)
  "Edit MESSAGE-ID in CHANNEL-ID with new CONTENT.
CALLBACK is called with the edited message object."
  (concordd--send-request
   "editMessage"
   `(:channelId ,channel-id :messageId ,message-id :content ,content)
   callback))

(defun concordd-delete-message (channel-id message-id &optional callback)
  "Delete MESSAGE-ID in CHANNEL-ID.
Optional CALLBACK is called on completion."
  (concordd--send-request
   "deleteMessage"
   `(:channelId ,channel-id :messageId ,message-id)
   (or callback (lambda (_result) (message "Message deleted")))))

;;; Simple UI

(defvar concordd-guilds nil
  "Cached list of guilds.")

(defvar concordd-current-guild nil
  "Currently selected guild ID.")

(defvar concordd-current-channel nil
  "Currently selected channel ID.")

(defvar concordd-guild-members nil
  "Hash table of guild ID -> members list.")

(defvar concordd-guild-roles nil
  "Hash table of guild ID -> roles list.")

(setq concordd-guild-members (make-hash-table :test 'equal))
(setq concordd-guild-roles (make-hash-table :test 'equal))

;;;###autoload
(defun concordd-browse ()
  "Open Concordd browser interface."
  (interactive)
  (unless (concordd-connected-p)
    (concordd-connect))
  
  ;; Fetch guilds
  (concordd-list-guilds
   (lambda (result)
     (setq concordd-guilds (plist-get result :guilds))
     (concordd--show-guild-list))))

(defun concordd--show-guild-list ()
  "Show list of guilds in a buffer."
  (let ((buf (get-buffer-create "*Concordd Guilds*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (concordd-guild-list-mode)
        (insert (propertize "Concordd Guilds\n\n" 'face 'bold))
        (dolist (guild concordd-guilds)
          (let ((name (plist-get guild :name))
                (id (plist-get guild :id)))
            (insert-button name
                          'action (lambda (_btn) (concordd--select-guild id))
                          'follow-link t)
            (insert "\n"))))
      (goto-char (point-min)))
    (pop-to-buffer buf)))

(defun concordd--select-guild (guild-id)
  "Select and show channels for GUILD-ID."
  (setq concordd-current-guild guild-id)
  (concordd-list-channels
   guild-id
   (lambda (result)
     (concordd--show-channel-list (plist-get result :channels)))))

(defun concordd--show-channel-list (channels)
  "Show list of CHANNELS in a buffer."
  (let ((buf (get-buffer-create "*Concordd Channels*"))
        (guild-name (cl-loop for g in concordd-guilds
                            when (string= (plist-get g :id) concordd-current-guild)
                            return (plist-get g :name))))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (concordd-channel-list-mode)
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
                            'action (lambda (_btn) (concordd--open-channel id name))
                            'follow-link t)
              (insert "\n")))))
      (goto-char (point-min)))
    (pop-to-buffer buf)))

(defun concordd--open-channel (channel-id channel-name)
  "Open messages for CHANNEL-ID with CHANNEL-NAME."
  (setq concordd-current-channel channel-id)
  (let ((buf (get-buffer-create (format "*Concordd: #%s*" channel-name))))
    (with-current-buffer buf
      (concordd-channel-mode)
      (setq-local concordd-channel-id channel-id)
      (setq-local concordd-channel-name channel-name)
      (setq-local concordd-channel-guild-id concordd-current-guild)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize (format "Channel: #%s\n\n" channel-name) 'face 'bold))
        (insert "Loading messages...\n\n")
        (insert (propertize "Keybindings: n=new message, p=load more, gr=reload, q=quit\n" 'face 'shadow))))
    (pop-to-buffer buf)
    
    ;; Load guild metadata (members and roles) for mention rendering
    (when concordd-current-guild
      (concordd--load-guild-metadata concordd-current-guild))
    
    ;; Load messages
    (concordd--load-channel-messages channel-id)))

(defun concordd--load-guild-metadata (guild-id)
  "Load members and roles for GUILD-ID into cache."
  (unless (gethash guild-id concordd-guild-members)
    (concordd-get-guild-members
     guild-id
     (lambda (result)
       (puthash guild-id (plist-get result :members) concordd-guild-members))))
  
  (unless (gethash guild-id concordd-guild-roles)
    (concordd-get-guild-roles
     guild-id
     (lambda (result)
       (puthash guild-id (plist-get result :roles) concordd-guild-roles)))))

(defun concordd--load-channel-messages (channel-id)
  "Load messages for CHANNEL-ID."
  (concordd-get-messages
   channel-id
   (lambda (result)
     (let ((messages (reverse (plist-get result :messages))))
       (concordd--display-messages channel-id messages nil)))
   50 nil))

(defun concordd-load-more-messages ()
  "Load older messages in current channel."
  (interactive)
  (unless concordd-channel-id
    (error "Not in a Concordd channel buffer"))
  
  (when concordd-loading-messages
    (message "Already loading messages...")
    (cl-return-from concordd-load-more-messages))
  
  (unless concordd-oldest-message-id
    (message "No older messages to load")
    (cl-return-from concordd-load-more-messages))
  
  (setq concordd-loading-messages t)
  (message "Loading older messages...")
  
  (concordd-get-messages
   concordd-channel-id
   (lambda (result)
     (setq concordd-loading-messages nil)
     (let ((messages (reverse (plist-get result :messages))))
       (if (null messages)
           (message "No more messages")
         (concordd--prepend-messages concordd-channel-id messages)
         (message "Loaded %d messages" (length messages)))))
   50
   concordd-oldest-message-id))

(defun concordd--display-messages (channel-id messages &optional keep-position)
  "Display MESSAGES for CHANNEL-ID in current buffer.
If KEEP-POSITION is non-nil, try to maintain cursor position."
  (let ((buf (cl-find-if
              (lambda (b)
                (with-current-buffer b
                  (and (eq major-mode 'concordd-channel-mode)
                       (string= concordd-channel-id channel-id))))
              (buffer-list))))
    (when buf
      (with-current-buffer buf
        (let ((inhibit-read-only t)
              (old-point (when keep-position (point))))
          (erase-buffer)
          (insert (propertize (format "Channel: #%s\n\n" concordd-channel-name) 'face 'bold))
          
          ;; Track oldest message for pagination
          (when messages
            (setq concordd-oldest-message-id (plist-get (car messages) :id)))
          
          ;; Insert messages
          (dolist (msg messages)
            (concordd--insert-message msg))
          
          ;; Add help text
          (goto-char (point-max))
          (insert "\n" (propertize "──────────────────────\n" 'face 'bold))
          (insert (propertize "Keybindings: n=new message, p=load more, gr=reload, q=quit\n" 'face 'shadow))
          
          ;; Restore or move to end
          (if (and keep-position old-point)
              (goto-char (min old-point (point-max)))
            (goto-char (point-max))))))))

(defun concordd--prepend-messages (channel-id messages)
  "Prepend MESSAGES to CHANNEL-ID buffer (for pagination)."
  (let ((buf (cl-find-if
              (lambda (b)
                (with-current-buffer b
                  (and (eq major-mode 'concordd-channel-mode)
                       (string= concordd-channel-id channel-id))))
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
              (setq concordd-oldest-message-id (plist-get (car messages) :id)))
            
            ;; Insert older messages at the top
            (dolist (msg messages)
              (concordd--insert-message msg))))))))

(defun concordd--insert-message (msg)
  "Insert a single message MSG into current buffer."
  (let* ((author (plist-get msg :author))
         (username (plist-get author :username))
         (content (plist-get msg :content))
         (timestamp (plist-get msg :timestamp))
         (time-str (format-time-string "%H:%M" (date-to-time timestamp)))
         ;; Use buffer-local guild-id instead of message's guild-id
         (guild-id concordd-channel-guild-id)
         (message-id (plist-get msg :id))
         (author-id (plist-get author :id))
         (start-pos (point)))
    
    (insert (propertize (format "[%s] " time-str) 'face 'shadow))
    (insert (propertize username 'face 'bold))
    (insert ": ")
    
    ;; Render content with mentions resolved
    (concordd--insert-content-with-mentions content guild-id)
    (insert "\n")
    
    ;; Add text properties to the entire message line for easy lookup
    (put-text-property start-pos (point) 'concordd-message-id message-id)
    (put-text-property start-pos (point) 'concordd-author-id author-id)
    (put-text-property start-pos (point) 'concordd-message-content content)))

(defun concordd--insert-content-with-mentions (content guild-id)
  "Insert CONTENT with mentions resolved using GUILD-ID cache."
  (let ((pos 0)
        (members (when guild-id (gethash guild-id concordd-guild-members)))
        (roles (when guild-id (gethash guild-id concordd-guild-roles))))
    
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

(defvar concordd-guild-list-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "q") #'quit-window)
    (define-key map (kbd "g") #'concordd-browse)
    map)
  "Keymap for `concordd-guild-list-mode'.")

(define-derived-mode concordd-guild-list-mode special-mode "Concordd-Guilds"
  "Major mode for browsing Concordd guilds."
  (setq buffer-read-only t))

(defvar concordd-channel-list-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "q") #'quit-window)
    (define-key map (kbd "g") #'concordd-browse)
    map)
  "Keymap for `concordd-channel-list-mode'.")

(define-derived-mode concordd-channel-list-mode special-mode "Concordd-Channels"
  "Major mode for browsing Concordd channels."
  (setq buffer-read-only t))

(defvar-local concordd-channel-id nil
  "Channel ID for current Concordd channel buffer.")

(defvar-local concordd-channel-name nil
  "Channel name for current Concordd channel buffer.")

(defvar-local concordd-channel-guild-id nil
  "Guild ID for current Concordd channel buffer.")

(defvar-local concordd-oldest-message-id nil
  "ID of the oldest message currently loaded in buffer.")

(defvar-local concordd-loading-messages nil
  "Non-nil if currently loading more messages.")

(defvar concordd-channel-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-n") #'concordd-compose-message)
    (define-key map (kbd "C-c C-r") #'concordd-reply-to-message-at-point)
    (define-key map (kbd "C-c C-l") #'concordd-channel-reload)
    (define-key map (kbd "C-c C-p") #'concordd-load-more-messages)
    (define-key map (kbd "C-c C-e") #'concordd-edit-message-at-point)
    (define-key map (kbd "C-c C-d") #'concordd-delete-message-at-point)
    (define-key map (kbd "q") #'quit-window)
    ;; Evil-friendly bindings (will work in normal state)
    (define-key map (kbd "n") #'concordd-compose-message)
    (define-key map (kbd "R") #'concordd-reply-to-message-at-point)
    (define-key map (kbd "gr") #'concordd-channel-reload)
    (define-key map (kbd "gp") #'concordd-load-more-messages)
    (define-key map (kbd "p") #'concordd-load-more-messages)
    (define-key map (kbd "e") #'concordd-edit-message-at-point)
    (define-key map (kbd "dd") #'concordd-delete-message-at-point)
    map)
  "Keymap for `concordd-channel-mode'.")

(define-derived-mode concordd-channel-mode special-mode "Concordd-Channel"
  "Major mode for Concordd channel messages.

Key bindings:
\\{concordd-channel-mode-map}

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
    (evil-set-initial-state 'concordd-channel-mode 'normal))
  
  ;; Register event handler for new messages
  (concordd-on 'messageCreated
              (lambda (params)
                (concordd--handle-message-created params))))

(defun concordd-compose-message ()
  "Open a compose buffer to send a message to current channel."
  (interactive)
  (unless concordd-channel-id
    (error "Not in a Concordd channel buffer"))
  
  (let* ((channel-id concordd-channel-id)
         (channel-name concordd-channel-name)
         (compose-buf (get-buffer-create (format "*Concordd Compose: #%s*" channel-name))))
    (pop-to-buffer compose-buf)
    (concordd-compose-mode)
    (setq-local concordd-channel-id channel-id)
    (setq-local concordd-channel-name channel-name)
    (erase-buffer)
    (insert (propertize (format "Composing message for #%s\n" channel-name) 'face 'bold))
    (insert (propertize "Press C-c C-c to send, C-c C-k to cancel\n\n" 'face 'shadow))
    (insert (propertize "──────────────────────\n\n" 'face 'bold))
    (goto-char (point-max))))

(defun concordd-reply-to-message-at-point ()
  "Reply to the message at point (not yet implemented)."
  (interactive)
  (message "Reply functionality not yet implemented"))

(defun concordd-edit-message-at-point ()
  "Edit the message at point if it's your own message."
  (interactive)
  (unless concordd-channel-id
    (error "Not in a Concordd channel buffer"))
  
  (let* ((message-id (get-text-property (point) 'concordd-message-id))
         (author-id (get-text-property (point) 'concordd-author-id))
         (content (get-text-property (point) 'concordd-message-content)))
    
    (unless message-id
      (error "No message at point"))
    
    ;; We need to get the current user ID to check ownership
    ;; For now, we'll just try to edit - the server will reject if not owned
    (let ((edit-buf (get-buffer-create (format "*Concordd Edit: %s*" message-id))))
      (pop-to-buffer edit-buf)
      (concordd-compose-mode)
      (setq-local concordd-channel-id concordd-channel-id)
      (setq-local concordd-editing-message-id message-id)
      (erase-buffer)
      (insert (propertize "Editing message\n" 'face 'bold))
      (insert (propertize "Press C-c C-c to save, C-c C-k to cancel\n\n" 'face 'shadow))
      (insert (propertize "──────────────────────\n\n" 'face 'bold))
      (insert content)
      (goto-char (point-max)))))

(defun concordd-delete-message-at-point ()
  "Delete the message at point if it's your own message."
  (interactive)
  (unless concordd-channel-id
    (error "Not in a Concordd channel buffer"))
  
  (let ((message-id (get-text-property (point) 'concordd-message-id)))
    
    (unless message-id
      (error "No message at point"))
    
    (when (y-or-n-p "Delete this message? ")
      (concordd-delete-message
       concordd-channel-id
       message-id
       (lambda (_result)
         (message "Message deleted"))))))

(defun concordd-channel-reload ()
  "Reload messages in current channel."
  (interactive)
  (when concordd-channel-id
    (setq concordd-oldest-message-id nil)
    (setq concordd-loading-messages nil)
    (concordd--load-channel-messages concordd-channel-id)))

;;; Compose mode

(defvar-local concordd-editing-message-id nil
  "Message ID being edited, if any.")

(defvar concordd-compose-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'concordd-compose-send)
    (define-key map (kbd "C-c C-k") #'concordd-compose-cancel)
    map)
  "Keymap for `concordd-compose-mode'.")

(define-derived-mode concordd-compose-mode text-mode "Concordd-Compose"
  "Major mode for composing Concordd messages.

Key bindings:
\\{concordd-compose-mode-map}

  C-c C-c - Send message
  C-c C-k - Cancel"
  (setq buffer-read-only nil)
  
  ;; Evil mode integration - start in insert state
  (when (and (boundp 'evil-mode) evil-mode)
    (evil-set-initial-state 'concordd-compose-mode 'insert)
    (evil-insert-state)))

(defun concordd-compose-send ()
  "Send the message from compose buffer."
  (interactive)
  (unless concordd-channel-id
    (error "Not in a Concordd compose buffer"))
  
  ;; Find the content after the separator
  (save-excursion
    (goto-char (point-min))
    (when (search-forward "──────────────────────\n\n" nil t)
      (let ((content (string-trim (buffer-substring (point) (point-max)))))
        (when (> (length content) 0)
          (if concordd-editing-message-id
              ;; Editing existing message
              (concordd-edit-message
               concordd-channel-id
               concordd-editing-message-id
               content
               (lambda (result)
                 (message "Message edited!")))
            ;; Sending new message
            (concordd-send-message
             concordd-channel-id
             content
             (lambda (result)
               (message "Message sent!"))))
          (kill-buffer (current-buffer)))))))

(defun concordd-compose-cancel ()
  "Cancel composing and close the buffer."
  (interactive)
  (when (y-or-n-p "Discard message? ")
    (kill-buffer (current-buffer))))


(defun concordd--handle-message-created (params)
  "Handle messageCreated event with PARAMS."
  (let* ((msg (plist-get params :message))
         (channel-id (plist-get msg :channelId)))
    ;; Update buffer if it exists and matches
    (dolist (buf (buffer-list))
      (with-current-buffer buf
        (when (and (eq major-mode 'concordd-channel-mode)
                   (string= concordd-channel-id channel-id))
          (let ((inhibit-read-only t))
            (save-excursion
              ;; Find the separator line and insert before it
              (goto-char (point-min))
              (if (search-forward "──────────────────────\n" nil t)
                  (progn
                    (forward-line -1)
                    (insert "\n")
                    (forward-line -1)
                    (concordd--insert-message msg))
                ;; No separator yet, just append
                (goto-char (point-max))
                (insert "\n")
                (concordd--insert-message msg)))))))))

;;; Provide

(provide 'concordd)

;;; concordd.el ends here
