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

(defun concordd-message--insert-header (username timestamp edited thread-id)
  "Insert message header with USERNAME, TIMESTAMP, EDITED marker, and THREAD-ID indicator."
  (let ((ts-str (concordd-message--format-timestamp timestamp))
        (author-str (propertize username 'face '(:weight bold :foreground "#5865F2"))))
    (if (eq concordd-message-timestamp-align 'right)
        (concordd-message--insert-header-right author-str ts-str edited thread-id)
      (concordd-message--insert-header-left author-str ts-str edited thread-id))
    (insert "\n")))

(defun concordd-message--insert-header-right (author-str ts-str edited thread-id)
  "Insert right-aligned header with AUTHOR-STR, TS-STR, EDITED, THREAD-ID."
  (let* ((parts (list author-str))
         (_ (when edited (push (propertize " (edited)" 'face 'italic) parts)))
         (_ (when thread-id
              (push (propertize " 🧵" 'face 'shadow 'help-echo "This message has a thread") parts)))
         (line-content (apply #'concat (nreverse parts)))
         (padding (max 1 (- (window-width) (string-width line-content) (string-width ts-str) 2))))
    (insert line-content)
    (insert (propertize (make-string padding ?\s) 'face 'shadow))
    (insert (propertize ts-str 'face 'shadow))))

(defun concordd-message--insert-header-left (author-str ts-str edited thread-id)
  "Insert left-aligned header with AUTHOR-STR, TS-STR, EDITED, THREAD-ID."
  (insert (propertize ts-str 'face 'shadow) " " author-str)
  (when edited (insert (propertize " (edited)" 'face 'italic)))
  (when thread-id
    (insert (propertize " 🧵" 'face 'shadow 'help-echo "This message has a thread"))))

(defun concordd-message--insert-content (content guild-id)
  "Insert message CONTENT with mention processing for GUILD-ID."
  (when (and content (> (length content) 0))
    (let ((content-start (point))
          (processed (if (fboundp 'concordd-format-preprocess-mentions)
                         (concordd-format-preprocess-mentions content guild-id)
                       content)))
      (insert (if (featurep 'markdown-mode)
                  (string-trim (concordd-message--render-markdown processed))
                processed))
      (when (fboundp 'concordd-format-postprocess-mentions)
        (save-excursion
          (save-restriction
            (narrow-to-region content-start (point))
            (concordd-format-postprocess-mentions guild-id)))))))

(defun concordd-message--format (message)
  "Pretty-printer function to format MESSAGE for ewoc display."
  (condition-case err
      (let* ((author (concordd-message-author message))
             (author-id (plist-get author :id))
             (state (concordd-message-state message))
             (edited (concordd-message-edited-timestamp message))
             (reactions (concordd-message-reactions message))
             (thread-id (concordd-message-thread-id message))
             (start-pos (point))
             (show-header (or edited reactions thread-id
                             (not concordd-message-group-by-author)
                             (not (equal author-id (plist-get state :prev-author-id))))))
        (when show-header
          (concordd-message--insert-header
           (concordd-message--format-author author)
           (concordd-message-timestamp message)
           edited thread-id))
        (concordd-message--insert-content
         (concordd-message-content message)
         (plist-get state :guild-id))
        (when reactions
          (insert "\n" (concordd-message--format-reactions reactions)))
        (insert "\n")
        (put-text-property start-pos (point) 'concordd-message-id (concordd-message-id message))
        (put-text-property start-pos (point) 'concordd-author-id author-id))
    (error
     (insert (propertize (format "[Error rendering message: %s]\n%S\n"
                                 (error-message-string err) message)
                         'face 'error)))))

(defun concordd-message--render-markdown (content)
  "Render CONTENT using markdown-view-mode.
Returns the formatted content as a string with text properties."
  (with-temp-buffer
    (insert content)
    (markdown-view-mode)
    (font-lock-ensure)
    ;; Return trimmed content to avoid alignment issues
    (string-trim (buffer-string))))

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
