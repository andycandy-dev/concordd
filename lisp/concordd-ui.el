;;; concordd-ui.el --- UI layer for Concordd -*- lexical-binding: t; -*-

;; Copyright (C) 2025 Concordd Project

;;; Commentary:

;; This file implements the user interface for browsing guilds, channels,
;; and messages in Concordd.

;;; Code:

(require 'cl-lib)

;;; Variables

(defvar concordd-ui-guilds nil
  "Cached list of guilds.")

(defvar concordd-ui-current-guild nil
  "Currently selected guild ID.")

(defvar concordd-ui-current-channel nil
  "Currently selected channel ID.")

(defvar concordd-ui-guild-members (make-hash-table :test 'equal)
  "Hash table of guild ID -> members list.")

(defvar concordd-ui-guild-roles (make-hash-table :test 'equal)
  "Hash table of guild ID -> roles list.")

(defvar-local concordd-ui-channel-id nil
  "Channel ID for current Concordd channel buffer.")

(defvar-local concordd-ui-channel-name nil
  "Channel name for current Concordd channel buffer.")

(defvar-local concordd-ui-channel-guild-id nil
  "Guild ID for current Concordd channel buffer.")

(defvar-local concordd-ui-oldest-message-id nil
  "ID of the oldest message currently loaded in buffer.")

(defvar-local concordd-ui-loading-messages nil
  "Non-nil if currently loading more messages.")

(defvar-local concordd-ui-editing-message-id nil
  "Message ID being edited, if any.")

;;; Guild list

(defun concordd-ui-show-guild-list (guilds)
  "Show list of GUILDS in a buffer."
  (setq concordd-ui-guilds guilds)
  (let ((buf (get-buffer-create "*Concordd Guilds*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (concordd-ui-guild-list-mode)
        (insert (propertize "Concordd Guilds\n\n" 'face 'bold))
        (dolist (guild guilds)
          (let ((name (plist-get guild :name))
                (id (plist-get guild :id)))
            (insert-button name
                          'action (lambda (_btn) (concordd-ui-select-guild id))
                          'follow-link t)
            (insert "\n"))))
      (goto-char (point-min)))
    (pop-to-buffer buf)))

(defun concordd-ui-select-guild (guild-id)
  "Select and show channels for GUILD-ID."
  (setq concordd-ui-current-guild guild-id)
  ;; Call back to main concordd API
  (concordd-list-channels
   guild-id
   (lambda (result)
     (concordd-ui-show-channel-list (plist-get result :channels)))))

;;; Channel list

(defun concordd-ui-show-channel-list (channels)
  "Show list of CHANNELS in a buffer."
  (let ((buf (get-buffer-create "*Concordd Channels*"))
        (guild-name (cl-loop for g in concordd-ui-guilds
                            when (string= (plist-get g :id) concordd-ui-current-guild)
                            return (plist-get g :name))))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (concordd-ui-channel-list-mode)
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
                            'action (lambda (_btn) (concordd-ui-open-channel id name))
                            'follow-link t)
              (insert "\n")))))
      (goto-char (point-min)))
    (pop-to-buffer buf)))

;;; Channel messages

(defun concordd-ui-open-channel (channel-id channel-name)
  "Open messages for CHANNEL-ID with CHANNEL-NAME."
  (setq concordd-ui-current-channel channel-id)
  (let ((buf (get-buffer-create (format "*Concordd: #%s*" channel-name))))
    (with-current-buffer buf
      (concordd-ui-channel-mode)
      (setq-local concordd-ui-channel-id channel-id)
      (setq-local concordd-ui-channel-name channel-name)
      (setq-local concordd-ui-channel-guild-id concordd-ui-current-guild)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize (format "Channel: #%s\n\n" channel-name) 'face 'bold))
        (insert "Loading messages...\n\n")
        (insert (propertize "Keybindings: n=new message, p=load more, gr=reload, q=quit\n" 'face 'shadow))))
    (pop-to-buffer buf)
    
    ;; Load guild metadata (members and roles) for mention rendering
    (when concordd-ui-current-guild
      (concordd-ui-load-guild-metadata concordd-ui-current-guild))
    
    ;; Load messages
    (concordd-get-messages
     channel-id
     (lambda (result)
       (let ((messages (reverse (plist-get result :messages))))
         (concordd-ui-display-messages channel-id messages nil)))
     50 nil)))

(defun concordd-ui-load-guild-metadata (guild-id)
  "Load members and roles for GUILD-ID into cache."
  (unless (gethash guild-id concordd-ui-guild-members)
    (concordd-get-guild-members
     guild-id
     (lambda (result)
       (puthash guild-id (plist-get result :members) concordd-ui-guild-members))))
  
  (unless (gethash guild-id concordd-ui-guild-roles)
    (concordd-get-guild-roles
     guild-id
     (lambda (result)
       (puthash guild-id (plist-get result :roles) concordd-ui-guild-roles)))))

(defun concordd-ui-load-more-messages ()
  "Load older messages in current channel."
  (interactive)
  (unless concordd-ui-channel-id
    (error "Not in a Concordd channel buffer"))
  
  (when concordd-ui-loading-messages
    (message "Already loading messages...")
    (cl-return-from concordd-ui-load-more-messages))
  
  (unless concordd-ui-oldest-message-id
    (message "No older messages to load")
    (cl-return-from concordd-ui-load-more-messages))
  
  (setq concordd-ui-loading-messages t)
  (message "Loading older messages...")
  
  (concordd-get-messages
   concordd-ui-channel-id
   (lambda (result)
     (setq concordd-ui-loading-messages nil)
     (let ((messages (reverse (plist-get result :messages))))
       (if (null messages)
           (message "No more messages")
         (concordd-ui-prepend-messages concordd-ui-channel-id messages)
         (message "Loaded %d messages" (length messages)))))
   50
   concordd-ui-oldest-message-id))

(defun concordd-ui-display-messages (channel-id messages &optional keep-position)
  "Display MESSAGES for CHANNEL-ID in current buffer.
If KEEP-POSITION is non-nil, try to maintain cursor position."
  (let ((buf (cl-find-if
              (lambda (b)
                (with-current-buffer b
                  (and (eq major-mode 'concordd-ui-channel-mode)
                       (string= concordd-ui-channel-id channel-id))))
              (buffer-list))))
    (when buf
      (with-current-buffer buf
        (let ((inhibit-read-only t)
              (old-point (when keep-position (point))))
          (erase-buffer)
          (insert (propertize (format "Channel: #%s\n\n" concordd-ui-channel-name) 'face 'bold))
          
          ;; Track oldest message for pagination
          (when messages
            (setq concordd-ui-oldest-message-id (plist-get (car messages) :id)))
          
          ;; Insert messages
          (dolist (msg messages)
            (concordd-ui-insert-message msg))
          
          ;; Add help text
          (goto-char (point-max))
          (insert "\n" (propertize "──────────────────────\n" 'face 'bold))
          (insert (propertize "Keybindings: n=new message, p=load more, gr=reload, q=quit\n" 'face 'shadow))
          
          ;; Restore or move to end
          (if (and keep-position old-point)
              (goto-char (min old-point (point-max)))
            (goto-char (point-max))))))))

(defun concordd-ui-prepend-messages (channel-id messages)
  "Prepend MESSAGES to CHANNEL-ID buffer (for pagination)."
  (let ((buf (cl-find-if
              (lambda (b)
                (with-current-buffer b
                  (and (eq major-mode 'concordd-ui-channel-mode)
                       (string= concordd-ui-channel-id channel-id))))
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
              (setq concordd-ui-oldest-message-id (plist-get (car messages) :id)))
            
            ;; Insert older messages at the top
            (dolist (msg messages)
              (concordd-ui-insert-message msg))))))))

(defun concordd-ui-insert-message (msg)
  "Insert a single message MSG into current buffer."
  (let* ((author (plist-get msg :author))
         (username (plist-get author :username))
         (content (plist-get msg :content))
         (timestamp (plist-get msg :timestamp))
         (time-str (format-time-string "%H:%M" (date-to-time timestamp)))
         (guild-id concordd-ui-channel-guild-id)
         (message-id (plist-get msg :id))
         (author-id (plist-get author :id))
         (start-pos (point)))
    
    (insert (propertize (format "[%s] " time-str) 'face 'shadow))
    (insert (propertize username 'face 'bold))
    (insert ": ")
    
    ;; Render content with mentions resolved
    (concordd-ui-insert-content-with-mentions content guild-id)
    (insert "\n")
    
    ;; Add text properties to the entire message line for easy lookup
    (put-text-property start-pos (point) 'concordd-message-id message-id)
    (put-text-property start-pos (point) 'concordd-author-id author-id)
    (put-text-property start-pos (point) 'concordd-message-content content)))

(defun concordd-ui-insert-content-with-mentions (content guild-id)
  "Insert CONTENT with mentions resolved using GUILD-ID cache."
  (let ((pos 0)
        (members (when guild-id (gethash guild-id concordd-ui-guild-members)))
        (roles (when guild-id (gethash guild-id concordd-ui-guild-roles))))
    
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

(defun concordd-ui-handle-message-created (params)
  "Handle messageCreated event with PARAMS."
  (let* ((msg (plist-get params :message))
         (channel-id (plist-get msg :channelId)))
    ;; Update buffer if it exists and matches
    (dolist (buf (buffer-list))
      (with-current-buffer buf
        (when (and (eq major-mode 'concordd-ui-channel-mode)
                   (string= concordd-ui-channel-id channel-id))
          (let ((inhibit-read-only t))
            (save-excursion
              ;; Find the separator line and insert before it
              (goto-char (point-min))
              (if (search-forward "──────────────────────\n" nil t)
                  (progn
                    (forward-line -1)
                    (insert "\n")
                    (forward-line -1)
                    (concordd-ui-insert-message msg))
                ;; No separator yet, just append
                (goto-char (point-max))
                (insert "\n")
                (concordd-ui-insert-message msg)))))))))

;;; Major modes

(defvar concordd-ui-guild-list-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "q") #'quit-window)
    (define-key map (kbd "g") #'concordd-browse)
    map)
  "Keymap for `concordd-ui-guild-list-mode'.")

(define-derived-mode concordd-ui-guild-list-mode special-mode "Concordd-Guilds"
  "Major mode for browsing Concordd guilds."
  (setq buffer-read-only t))

(defvar concordd-ui-channel-list-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "q") #'quit-window)
    (define-key map (kbd "g") #'concordd-browse)
    map)
  "Keymap for `concordd-ui-channel-list-mode'.")

(define-derived-mode concordd-ui-channel-list-mode special-mode "Concordd-Channels"
  "Major mode for browsing Concordd channels."
  (setq buffer-read-only t))

(defvar concordd-ui-channel-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-n") #'concordd-ui-compose-message)
    (define-key map (kbd "C-c C-r") #'concordd-ui-reply-to-message-at-point)
    (define-key map (kbd "C-c C-l") #'concordd-ui-channel-reload)
    (define-key map (kbd "C-c C-p") #'concordd-ui-load-more-messages)
    (define-key map (kbd "C-c C-e") #'concordd-ui-edit-message-at-point)
    (define-key map (kbd "C-c C-d") #'concordd-ui-delete-message-at-point)
    (define-key map (kbd "q") #'quit-window)
    ;; Evil-friendly bindings
    (define-key map (kbd "n") #'concordd-ui-compose-message)
    (define-key map (kbd "R") #'concordd-ui-reply-to-message-at-point)
    (define-key map (kbd "gr") #'concordd-ui-channel-reload)
    (define-key map (kbd "gp") #'concordd-ui-load-more-messages)
    (define-key map (kbd "p") #'concordd-ui-load-more-messages)
    (define-key map (kbd "e") #'concordd-ui-edit-message-at-point)
    (define-key map (kbd "dd") #'concordd-ui-delete-message-at-point)
    map)
  "Keymap for `concordd-ui-channel-mode'.")

(define-derived-mode concordd-ui-channel-mode special-mode "Concordd-Channel"
  "Major mode for Concordd channel messages.

Key bindings:
\\{concordd-ui-channel-mode-map}

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
    (evil-set-initial-state 'concordd-ui-channel-mode 'normal))
  
  ;; Register event handler for new messages
  (concordd-on 'messageCreated #'concordd-ui-handle-message-created))

(defun concordd-ui-compose-message ()
  "Open a compose buffer to send a message to current channel."
  (interactive)
  (unless concordd-ui-channel-id
    (error "Not in a Concordd channel buffer"))
  
  (let* ((channel-id concordd-ui-channel-id)
         (channel-name concordd-ui-channel-name)
         (compose-buf (get-buffer-create (format "*Concordd Compose: #%s*" channel-name))))
    (pop-to-buffer compose-buf)
    (concordd-ui-compose-mode)
    (setq-local concordd-ui-channel-id channel-id)
    (setq-local concordd-ui-channel-name channel-name)
    (erase-buffer)
    (insert (propertize (format "Composing message for #%s\n" channel-name) 'face 'bold))
    (insert (propertize "Press C-c C-c to send, C-c C-k to cancel\n\n" 'face 'shadow))
    (insert (propertize "──────────────────────\n\n" 'face 'bold))
    (goto-char (point-max))))

(defun concordd-ui-reply-to-message-at-point ()
  "Reply to the message at point (not yet implemented)."
  (interactive)
  (message "Reply functionality not yet implemented"))

(defun concordd-ui-edit-message-at-point ()
  "Edit the message at point if it's your own message."
  (interactive)
  (unless concordd-ui-channel-id
    (error "Not in a Concordd channel buffer"))
  
  (let* ((message-id (get-text-property (point) 'concordd-message-id))
         (content (get-text-property (point) 'concordd-message-content)))
    
    (unless message-id
      (error "No message at point"))
    
    (let ((edit-buf (get-buffer-create (format "*Concordd Edit: %s*" message-id))))
      (pop-to-buffer edit-buf)
      (concordd-ui-compose-mode)
      (setq-local concordd-ui-channel-id concordd-ui-channel-id)
      (setq-local concordd-ui-editing-message-id message-id)
      (erase-buffer)
      (insert (propertize "Editing message\n" 'face 'bold))
      (insert (propertize "Press C-c C-c to save, C-c C-k to cancel\n\n" 'face 'shadow))
      (insert (propertize "──────────────────────\n\n" 'face 'bold))
      (insert content)
      (goto-char (point-max)))))

(defun concordd-ui-delete-message-at-point ()
  "Delete the message at point if it's your own message."
  (interactive)
  (unless concordd-ui-channel-id
    (error "Not in a Concordd channel buffer"))
  
  (let ((message-id (get-text-property (point) 'concordd-message-id)))
    
    (unless message-id
      (error "No message at point"))
    
    (when (y-or-n-p "Delete this message? ")
      (concordd-delete-message
       concordd-ui-channel-id
       message-id
       (lambda (_result)
         (message "Message deleted"))))))

(defun concordd-ui-channel-reload ()
  "Reload messages in current channel."
  (interactive)
  (when concordd-ui-channel-id
    (setq concordd-ui-oldest-message-id nil)
    (setq concordd-ui-loading-messages nil)
    (concordd-get-messages
     concordd-ui-channel-id
     (lambda (result)
       (let ((messages (reverse (plist-get result :messages))))
         (concordd-ui-display-messages concordd-ui-channel-id messages nil)))
     50 nil)))

;;; Compose mode

(defvar concordd-ui-compose-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'concordd-ui-compose-send)
    (define-key map (kbd "C-c C-k") #'concordd-ui-compose-cancel)
    map)
  "Keymap for `concordd-ui-compose-mode'.")

(define-derived-mode concordd-ui-compose-mode text-mode "Concordd-Compose"
  "Major mode for composing Concordd messages.

Key bindings:
\\{concordd-ui-compose-mode-map}

  C-c C-c - Send message
  C-c C-k - Cancel"
  (setq buffer-read-only nil)
  
  ;; Evil mode integration - start in insert state
  (when (and (boundp 'evil-mode) evil-mode)
    (evil-set-initial-state 'concordd-ui-compose-mode 'insert)
    (evil-insert-state)))

(defun concordd-ui-compose-send ()
  "Send the message from compose buffer."
  (interactive)
  (unless concordd-ui-channel-id
    (error "Not in a Concordd compose buffer"))
  
  ;; Find the content after the separator
  (save-excursion
    (goto-char (point-min))
    (when (search-forward "──────────────────────\n\n" nil t)
      (let ((content (string-trim (buffer-substring (point) (point-max)))))
        (when (> (length content) 0)
          (if concordd-ui-editing-message-id
              ;; Editing existing message
              (concordd-edit-message
               concordd-ui-channel-id
               concordd-ui-editing-message-id
               content
               (lambda (result)
                 (message "Message edited!")))
            ;; Sending new message
            (concordd-send-message
             concordd-ui-channel-id
             content
             (lambda (result)
               (message "Message sent!"))))
          (kill-buffer (current-buffer)))))))

(defun concordd-ui-compose-cancel ()
  "Cancel composing and close the buffer."
  (interactive)
  (when (y-or-n-p "Discard message? ")
    (kill-buffer (current-buffer))))

(provide 'concordd-ui)

;;; concordd-ui.el ends here
