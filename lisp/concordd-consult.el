;;; concordd-consult.el --- Consult integration for Concordd -*- lexical-binding: t; -*-

;; Copyright (C) 2025 Concordd Project
;; Author: Andrej Novikov
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1") (consult "0.35"))
;; Keywords: comm, discord

;;; Commentary:

;; This file provides consult-based navigation for Concordd, offering
;; a modern incremental narrowing interface for browsing Discord.
;;
;; Main entry points:
;; - `consult-concordd-browse' - Start with guild selection
;; - `consult-concordd-activity' - Browse all channels/threads by recent activity
;; - `consult-concordd-dms' - Browse direct messages
;; - `consult-concordd-channel' - Browse channels in a guild
;;
;; The activity feed is particularly useful for finding recent conversations
;; across all channels and threads in a guild, sorted by latest message.

;;; Code:

(require 'consult)

;; Declare functions to avoid circular dependencies
(declare-function concordd-list-guilds "concordd")
(declare-function concordd-list-channels "concordd")
(declare-function concordd-list-dms "concordd")
(declare-function concordd-list-threads "concordd")
(declare-function concordd-ui-v2-open-channel "concordd-ui-v2")

;;; Customization

(defgroup concordd-consult nil
  "Consult integration for Concordd."
  :group 'concordd)

(defcustom concordd-consult-preview-enabled t
  "Whether to enable live preview when selecting channels."
  :type 'boolean
  :group 'concordd-consult)

;;; Guild Selection

(defvar concordd-consult--guilds-cache nil
  "Cached list of guilds.")

(defvar concordd-consult--guilds-cache-alist nil
  "Alist mapping guild names to their data.")

(defun concordd-consult--guild-annotate (cand)
  "Annotate guild candidate CAND with properties."
  (when-let* ((data (cdr (assoc cand concordd-consult--guilds-cache-alist)))
              (owner-id (plist-get data :owner-id))
              (has-icon (plist-get data :has-icon)))
    (concat
     (propertize " " 'display '(space :align-to 40))
     (if has-icon (propertize "[icon] " 'face 'font-lock-comment-face) "")
     (propertize (format "Owner: %s" (substring owner-id 0 8))
                 'face 'font-lock-doc-face))))

(defun concordd-consult--guild-candidates ()
  "Return list of guild candidates for consult."
  (let ((candidates (mapcar (lambda (guild)
                              (let* ((name (plist-get guild :name))
                                     (id (plist-get guild :id))
                                     (owner-id (plist-get guild :ownerId))
                                     (icon (plist-get guild :icon)))
                                (cons name (list :id id 
                                                :guild guild 
                                                :owner-id owner-id 
                                                :has-icon (not (null icon))))))
                            concordd-consult--guilds-cache)))
    ;; Store for annotate function
    (setq concordd-consult--guilds-cache-alist candidates)
    candidates))

;;;###autoload
(defun consult-concordd-guild ()
  "Select a Discord guild using consult."
  (interactive)
  (message "Loading guilds...")
  (concordd-list-guilds
   (lambda (result)
     (setq concordd-consult--guilds-cache (plist-get result :guilds))
     (message "Guilds loaded: %d" (length concordd-consult--guilds-cache))
     (let* ((candidates (concordd-consult--guild-candidates))
            (selected (consult--read
                       candidates
                       :prompt "Guild: "
                       :sort nil
                       :require-match t
                       :category 'concordd-guild
                       :annotate #'concordd-consult--guild-annotate
                       :lookup #'consult--lookup-cdr)))
       (if selected
           (let ((guild-id (plist-get selected :id)))
             (message "Selected guild ID: %s" guild-id)
             (consult-concordd-channel guild-id))
         (message "No guild selected"))))))

;;; Channel Selection

(defvar concordd-consult--channels-cache-alist nil
  "Alist mapping channel display strings to their data.")

(defun concordd-consult--channel-annotate (cand)
  "Annotate channel candidate CAND with properties."
  (when-let ((data (cdr (assoc cand concordd-consult--channels-cache-alist))))
    (let* ((type (plist-get data :type))
           (parent-id (plist-get data :parent-id))
           (parent-name (plist-get data :parent-name))
           (mention-count (plist-get data :mention-count))
           (mentioned (plist-get data :mentioned))
           (message-count (plist-get data :message-count))
           (parts '()))
      ;; Add type information
      (push (propertize
             (pcase type
               (0 "text")
               (2 "voice")
               (5 "announce")
               (15 "forum")
               (_ (format "type:%d" type)))
             'face 'font-lock-type-face)
            parts)
      ;; Add parent/category name if nested
      (when (and parent-id (not (string-empty-p parent-id)))
        (push (propertize (format "in:%s" (or parent-name "?"))
                          'face 'font-lock-keyword-face)
              parts))
      ;; Add mention count
      (when (and mentioned (> mention-count 0))
        (push (propertize (format "@%d" mention-count) 'face 'font-lock-warning-face)
              parts))
      ;; Add thread count for forum channels
      (when (and (= type 15) message-count (> message-count 0))
        (push (propertize (format "%d threads" message-count)
                          'face 'font-lock-comment-face)
              parts))
      (when parts
        (concat
         (propertize " " 'display '(space :align-to 50))
         (string-join (nreverse parts) " "))))))

(defun concordd-consult--channel-type-icon (type)
  "Get icon for channel TYPE."
  (pcase type
    (0 "#")      ; Text
    (2 "🔊")     ; Voice
    (4 "📁")     ; Category
    (5 "📢")     ; Announcement
    (15 "💬")    ; Forum
    (_ "•")))

(defun concordd-consult--channel-candidates (channels)
  "Return list of channel candidates from CHANNELS for consult."
  (let (result
        (parent-map (make-hash-table :test 'equal)))
    ;; First pass: build parent ID -> name map
    (dolist (channel channels)
      (let ((id (plist-get channel :id))
            (name (plist-get channel :name)))
        (puthash id name parent-map)))
    ;; Second pass: build candidates
    (dolist (channel channels)
      (let* ((name (plist-get channel :name))
             (id (plist-get channel :id))
             (type (plist-get channel :type))
             (position (plist-get channel :position))
             (parent-id (plist-get channel :parentId))
             (parent-name (when parent-id (gethash parent-id parent-map)))
             (icon (concordd-consult--channel-type-icon type))
             (unread (eq (plist-get channel :unread) t))
             (mentioned (eq (plist-get channel :mentioned) t))
             (mention-count (or (plist-get channel :mentionCount) 0))
             (message-count (or (plist-get channel :messageCount) 0))
             ;; Add indicators
             (prefix (concat
                     (if mentioned "@ " "")
                     (if unread "● " "")
                     icon))
             ;; Truncate long names to prevent overflow (same as threads)
             (truncated-name (truncate-string-to-width name 50 nil nil "…"))
             (display (format "%s%s" prefix truncated-name)))
        ;; Only show displayable channel types (not categories)
        (unless (= type 4)
          (push (cons display 
                      (list :id id 
                            :name name 
                            :type type 
                            :channel channel
                            :position position
                            :parent-id parent-id
                            :parent-name parent-name
                            :unread unread
                            :mentioned mentioned
                            :mention-count mention-count
                            :message-count message-count))
                result))))
    (setq result (nreverse result))
    ;; Store for annotate function  
    (setq concordd-consult--channels-cache-alist result)
    result))

(defun concordd-consult--channel-narrow-predicate (type)
  "Return predicate to narrow to channel TYPE."
  (lambda (cand)
    (when-let ((data (cdr (assoc cand concordd-consult--channels-cache-alist))))
      (= (plist-get data :type) type))))

(defun concordd-consult--open-channel (channel-id channel-name channel-type guild-id)
  "Open CHANNEL-ID with CHANNEL-NAME of CHANNEL-TYPE in GUILD-ID."
  (pcase channel-type
    (15 (consult-concordd-forum-thread channel-id channel-name guild-id))
    (_ (require 'concordd-ui-v2)
       (concordd-ui-v2-open-channel channel-id channel-name guild-id))))

;;;###autoload
(defun consult-concordd-channel (&optional guild-id)
  "Select a Discord channel using consult.
If GUILD-ID is provided, show channels for that guild.
Otherwise, prompt for guild first."
  (interactive)
  (if guild-id
      (progn
        (message "Loading channels for guild %s..." guild-id)
        (concordd-list-channels
         guild-id
         (lambda (result)
           (let* ((channels (plist-get result :channels))
                  (candidates (concordd-consult--channel-candidates channels)))
             (if (null candidates)
                 (message "No channels found in guild")
               (let ((selected (consult--read
                               candidates
                               :prompt "Channel: "
                               :sort nil
                               :require-match t
                               :category 'concordd-channel
                               :annotate #'concordd-consult--channel-annotate
                               :lookup #'consult--lookup-cdr
                               :narrow
                               `((?t . ,(concordd-consult--channel-narrow-predicate 0))
                                 (?v . ,(concordd-consult--channel-narrow-predicate 2))
                                 (?a . ,(concordd-consult--channel-narrow-predicate 5))
                                 (?f . ,(concordd-consult--channel-narrow-predicate 15))))))
                 (when selected
                   (let ((channel-id (plist-get selected :id))
                         (channel-name (plist-get selected :name))
                         (channel-type (plist-get selected :type)))
                     (message "Selected channel: %s (type %s)" channel-name channel-type)
                     (concordd-consult--open-channel channel-id channel-name channel-type guild-id))))))))
    (consult-concordd-guild))))

;;; Forum Thread Selection

(defvar concordd-consult--threads-cache-alist nil
  "Alist mapping thread display strings to their data.")

(defun concordd-consult--thread-annotate (cand)
  "Annotate thread candidate CAND with properties."
  (when-let ((data (cdr (assoc cand concordd-consult--threads-cache-alist))))
    (let* ((thread-id (plist-get data :id))
           (message-count (plist-get data :message-count))
           (archived (plist-get data :archived))
           (locked (plist-get data :locked))
           (parts '()))
      ;; Add message count
      (push (propertize (format "%d replies" message-count)
                        'face 'font-lock-comment-face)
            parts)
      ;; Add status indicators
      (when archived
        (push (propertize "archived" 'face 'font-lock-keyword-face)
              parts))
      (when locked
        (push (propertize "locked" 'face 'font-lock-warning-face)
              parts))
      (concat
       (propertize " " 'display '(space :align-to 60))
       (string-join (nreverse parts) " ")))))

(defun concordd-consult--thread-candidates (threads)
  "Return list of thread candidates from THREADS for consult."
  (let ((candidates
         (mapcar (lambda (thread)
                   (let* ((name (plist-get thread :name))
                          (id (plist-get thread :id))
                          (message-count (or (plist-get thread :messageCount) 0))
                          (metadata (plist-get thread :thread_metadata))
                          (archived (and metadata (plist-get metadata :archived)))
                          (locked (and metadata (plist-get metadata :locked)))
                          ;; Truncate long names to prevent overflow
                          (truncated-name (truncate-string-to-width name 55 nil nil "…"))
                          ;; Add indicators to display
                          (indicators (concat
                                      (if archived "🗃 " "")
                                      (if locked "🔒 " "")))
                          (display (format "%s%s" indicators truncated-name)))
                     (cons display (list :id id
                                        :name name
                                        :thread thread
                                        :message-count message-count
                                        :archived archived
                                        :locked locked))))
                 threads)))
    ;; Store for annotate function
    (setq concordd-consult--threads-cache-alist candidates)
    candidates))

;;;###autoload
(defun consult-concordd-forum-thread (channel-id channel-name guild-id)
  "Select a forum thread from CHANNEL-ID with CHANNEL-NAME in GUILD-ID using consult."
  (interactive
   (let ((channel-id (read-string "Channel ID: "))
         (channel-name (read-string "Channel name: "))
         (guild-id (read-string "Guild ID: ")))
     (list channel-id channel-name guild-id)))
  (concordd-list-threads
   channel-id
   (lambda (result)
     (let* ((threads (plist-get result :threads))
            (candidates (concordd-consult--thread-candidates threads)))
       (if (null candidates)
           (message "No threads in forum channel: %s" channel-name)
         (let ((selected (consult--read
                         candidates
                         :prompt (format "Thread in #%s: " channel-name)
                         :sort nil
                         :require-match t
                         :category 'concordd-thread
                         :annotate #'concordd-consult--thread-annotate
                         :lookup #'consult--lookup-cdr)))
           (when selected
             (let ((thread-id (plist-get selected :id))
                   (thread-name (plist-get selected :name)))
               (require 'concordd-ui-v2)
               (concordd-ui-v2-open-channel thread-id thread-name guild-id)))))))))

;;; Browse Entry Point

;;;###autoload
(defun consult-concordd-browse ()
  "Main entry point for Concordd consult navigation.
Starts with guild selection."
  (interactive)
  (consult-concordd-guild))

;;;###autoload
(defun consult-concordd-dms ()
  "Browse direct message channels using consult."
  (interactive)
  (require 'concordd-ui-v2)
  (concordd-list-dms
   (lambda (result)
     (let* ((channels (plist-get result :channels))
            (candidates
             (mapcar (lambda (ch)
                       (let ((name (plist-get ch :name))
                             (unread (plist-get ch :unread))
                             (mentions (plist-get ch :mentionCount)))
                         ;; Return cons cell: (display-name . channel-plist)
                         (cons (propertize name
                                          'unread unread
                                          'mentions mentions)
                               ch)))
                     channels)))
       (when-let ((selected (consult--read
                            candidates
                            :prompt "Direct Messages: "
                            :category 'concordd-dm
                            :sort nil
                            :require-match t
                            :annotate
                            (lambda (cand)
                              (let ((unread (get-text-property 0 'unread cand))
                                    (mentions (get-text-property 0 'mentions cand)))
                                (concat
                                 (propertize " " 'display '(space :align-to 40))
                                 (if (eq unread t)
                                     (propertize "[unread]" 'face 'warning)
                                   "")
                                 (when (and mentions (> mentions 0))
                                   (propertize (format " @%d" mentions)
                                              'face 'error)))))
                            :lookup #'consult--lookup-cdr)))
         (let ((id (plist-get selected :id))
               (name (plist-get selected :name)))
           (concordd-ui-v2-open-channel id name nil)))))))

;;;###autoload
(defun consult-concordd-activity (&optional guild-id)
  "Browse all channels in a guild sorted by recent activity.
If GUILD-ID is provided, uses it; otherwise prompts for guild selection.
This is like `consult-concordd-channel' but sorted by last message time."
  (interactive)
  (if guild-id
      (progn
        (message "Loading activity for guild %s..." guild-id)
        (concordd-list-channels
         guild-id
         (lambda (result)
           (let* ((channels (plist-get result :channels))
                  ;; Sort by lastMessageId before creating candidates
                  (sorted-channels
                   (sort (copy-sequence channels)
                         (lambda (a b)
                           (let ((a-id (or (plist-get a :lastMessageId) "0"))
                                 (b-id (or (plist-get b :lastMessageId) "0")))
                             (string> a-id b-id)))))
                  (candidates (concordd-consult--channel-candidates sorted-channels)))
             (if (null candidates)
                 (message "No channels found in guild")
               (let ((selected (consult--read
                               candidates
                               :prompt "Recent Activity: "
                               :sort nil  ; Don't re-sort, we already sorted
                               :require-match t
                               :category 'concordd-activity
                               :annotate #'concordd-consult--channel-annotate
                               :lookup #'consult--lookup-cdr)))
                 (when selected
                   (let ((channel-id (plist-get selected :id))
                         (channel-name (plist-get selected :name))
                         (channel-type (plist-get selected :type)))
                     (concordd-consult--open-channel channel-id channel-name channel-type guild-id))))))))
    (concordd-list-guilds
     (lambda (result)
       (let* ((guilds (plist-get result :guilds))
              (guild (consult--read
                      (mapcar (lambda (g)
                                (cons (plist-get g :name) g))
                              guilds)
                      :prompt "Select Guild: "
                      :category 'concordd-guild
                      :sort nil
                      :require-match t
                      :lookup #'consult--lookup-cdr)))
         (when guild
           (consult-concordd-activity (plist-get guild :id)))))))))

;;; Embark Integration

(with-eval-after-load 'embark
  (defvar embark-concordd-guild-map
    (let ((map (make-sparse-keymap)))
      (define-key map (kbd "RET") #'consult-concordd-channel)
      map)
    "Keymap for actions on Concordd guilds.")

  (defvar embark-concordd-channel-map
    (let ((map (make-sparse-keymap)))
      (define-key map (kbd "RET") (lambda ()
                                    (interactive)
                                    (let ((id (get-text-property (point) 'channel-id))
                                          (name (get-text-property (point) 'channel-name))
                                          (guild (get-text-property (point) 'guild-id)))
                                      (concordd-ui-v2-open-channel id name guild))))
      map)
    "Keymap for actions on Concordd channels.")

  (add-to-list 'embark-keymap-alist '(concordd-guild . embark-concordd-guild-map))
  (add-to-list 'embark-keymap-alist '(concordd-channel . embark-concordd-channel-map)))

(provide 'concordd-consult)
;;; concordd-consult.el ends here
