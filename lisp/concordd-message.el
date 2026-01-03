;;; concordd-message.el --- Message data structures for Concordd -*- lexical-binding: t; -*-

;; Copyright (C) 2025 Concordd Project
;; Author: Andrej Novikov
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1") (markdown-mode "2.5"))
;; Keywords: comm, discord

;;; Commentary:

;; This file defines the message data structures and rendering functions
;; for the Concordd EWOC-based UI.
;; Uses markdown-view-mode for content rendering.

;;; Code:

(require 'cl-lib)
;; concordd-format is loaded on-demand for formatting
(declare-function concordd-format-preprocess-mentions "concordd-format")
(declare-function concordd-format-postprocess-mentions "concordd-format")
(require 'markdown-mode nil t)

;;; Customization

(defcustom concordd-message-timestamp-align 'right
  "Where to align message timestamps."
  :type '(choice (const :tag "Left" left)
                 (const :tag "Right" right))
  :group 'concordd)

(defcustom concordd-message-group-by-author t
  "Group consecutive messages from the same author.
When non-nil, don't repeat username for consecutive messages."
  :type 'boolean
  :group 'concordd)

;;; Data Structures

(cl-defstruct concordd-message
  "Represents a Discord message.
Fields:
  id                - Message ID (string)
  channel-id        - Channel ID (string)
  author            - Author plist (:id :username :avatar)
  content           - Message content string
  timestamp         - ISO timestamp string
  edited-timestamp  - Edit timestamp (if edited)
  mentions          - List of mentioned user IDs
  attachments       - List of attachment plists
  embeds            - List of embed plists
  reactions         - List of reaction plists
  thread-id         - Thread ID (if in thread)
  reference         - Reply reference plist
  state             - Local state plist (:expanded :highlighted etc.)"
  id
  channel-id
  author
  content
  timestamp
  edited-timestamp
  mentions
  attachments
  embeds
  reactions
  thread-id
  reference
  (state nil))

;;; Conversion Functions

(defun concordd-message-from-plist (plist)
  "Create concordd-message struct from IPC PLIST."
  (make-concordd-message
   :id (plist-get plist :id)
   :channel-id (plist-get plist :channelId)
   :author (plist-get plist :author)
   :content (or (plist-get plist :content) "")
   :timestamp (plist-get plist :timestamp)
   :edited-timestamp (plist-get plist :editedTimestamp)
   :mentions (plist-get plist :mentions)
   :attachments (plist-get plist :attachments)
   :embeds (plist-get plist :embeds)
   :reactions (plist-get plist :reactions)
   :thread-id (plist-get plist :threadId)
   :reference (plist-get plist :messageReference)))

;;; Formatting Functions

(defun concordd-message--format-timestamp (timestamp)
  "Format TIMESTAMP string to display format."
  (condition-case nil
      (format-time-string "[%H:%M]" (date-to-time timestamp))
    (error "[??:??]")))

(defun concordd-message--format-author (author)
  "Format AUTHOR plist to display name."
  (or (plist-get author :username)
      "Unknown"))

(defun concordd-message--format (message)
  "Pretty-printer function to format MESSAGE for ewoc display.
This is called by ewoc whenever a message node needs to be rendered."
  (condition-case err
      (let* ((author (concordd-message-author message))
             (username (concordd-message--format-author author))
             (author-id (plist-get author :id))
             (content (concordd-message-content message))
             (timestamp (concordd-message-timestamp message))
             (edited (concordd-message-edited-timestamp message))
             (reactions (concordd-message-reactions message))
             (thread-id (concordd-message-thread-id message))
             (guild-id (plist-get (concordd-message-state message) :guild-id))
             (prev-author-id (plist-get (concordd-message-state message) :prev-author-id))
             (start-pos (point))
             ;; Always show header if message has reactions, thread, or is edited
             ;; This ensures important metadata is never hidden by grouping
             (force-header (or reactions thread-id edited))
             (show-header (or force-header
                             (not concordd-message-group-by-author)
                             (not (equal author-id prev-author-id)))))
        
        ;; Insert header (timestamp + author) if needed
        (when show-header
          (let ((ts-str (concordd-message--format-timestamp timestamp))
                (author-str (propertize username
                                       'face '(:weight bold :foreground "#5865F2"))))
            (if (eq concordd-message-timestamp-align 'right)
                ;; Right-aligned timestamp
                (let* ((line-parts (list author-str))
                       ;; Add edited marker
                       (_ (when edited
                            (push (propertize " (edited)" 'face 'italic) line-parts)))
                       ;; Add thread indicator
                       (_ (when thread-id
                            (push (propertize " 🧵" 'face 'shadow
                                            'help-echo "This message has a thread")
                                  line-parts)))
                       (line-content (apply #'concat (nreverse line-parts)))
                       (content-width (string-width line-content))
                       (ts-width (string-width ts-str))
                       (window-width (window-width))
                       (padding (max 1 (- window-width content-width ts-width 2))))
                  (insert line-content)
                  (insert (propertize (make-string padding ?\s) 'face 'shadow))
                  (insert (propertize ts-str 'face 'shadow)))
              ;; Left-aligned timestamp
              (insert (propertize ts-str 'face 'shadow))
              (insert " ")
              (insert author-str)
              (when edited
                (insert (propertize " (edited)" 'face 'italic)))
              (when thread-id
                (insert (propertize " 🧵" 'face 'shadow
                                   'help-echo "This message has a thread"))))
            (insert "\n")))
        
        ;; Insert message content
        (when (and content (> (length content) 0))
          (let ((content-start (point)))
            ;; Add indentation for grouped messages
            (when (and (not show-header) concordd-message-group-by-author)
              (insert "  "))
            
            ;; Pre-process mentions if concordd-format is loaded
            (let ((processed-content 
                   (if (fboundp 'concordd-format-preprocess-mentions)
                       (concordd-format-preprocess-mentions content guild-id)
                     content)))
              ;; Insert content in a temporary markdown-view-mode buffer to get formatting
              (if (featurep 'markdown-mode)
                  (let ((formatted (concordd-message--render-markdown processed-content)))
                    (insert formatted))
                ;; Fallback: just insert plain text
                (insert processed-content)))
            
            ;; Post-process: add mention faces if concordd-format is loaded
            (when (fboundp 'concordd-format-postprocess-mentions)
              (save-excursion
                (save-restriction
                  (narrow-to-region content-start (point))
                  (concordd-format-postprocess-mentions guild-id))))))
        
        ;; Insert reactions if present (always on their own line)
        (when reactions
          (insert "\n")
          (when (and (not show-header) concordd-message-group-by-author)
            (insert "  "))
          (insert (concordd-message--format-reactions reactions)))
        
        (insert "\n")
        
        ;; Store message ID and author ID as text properties
        (put-text-property start-pos (point)
                          'concordd-message-id (concordd-message-id message))
        (put-text-property start-pos (point)
                          'concordd-author-id author-id))
    
    (error
     ;; Graceful error handling: display error and raw data
     (insert (propertize
              (format "[Error rendering message: %s]\n%S\n"
                      (error-message-string err)
                      message)
              'face 'error)))))

(defun concordd-message--render-markdown (content)
  "Render CONTENT using markdown-view-mode.
Returns the formatted content as a string with text properties."
  (with-temp-buffer
    (insert content)
    (markdown-view-mode)
    (font-lock-ensure)
    (buffer-string)))

(defun concordd-message--format-reactions (reactions)
  "Format REACTIONS list into a display string.
REACTIONS is a list of plists with :emoji, :count, and :me keys."
  (if (null reactions)
      ""
    (concat
     (propertize "↪ " 'face 'shadow)  ; Reaction prefix
     (mapconcat
      (lambda (reaction)
        (let ((emoji (plist-get reaction :emoji))
              (count (plist-get reaction :count))
              (me (plist-get reaction :me)))
          (propertize
           (format "%s %d" emoji count)
           'face (if me '(:weight bold :background "#5865F2" :foreground "white") 
                   '(:background "#2C2F33" :foreground "#99AAB5")))))
      reactions
      " "))))

(provide 'concordd-message)
;;; concordd-message.el ends here
