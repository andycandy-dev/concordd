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
             (content (concordd-message-content message))
             (timestamp (concordd-message-timestamp message))
             (edited (concordd-message-edited-timestamp message))
             (guild-id (plist-get (concordd-message-state message) :guild-id))
             (start-pos (point)))
        
        ;; Insert timestamp and author header
        (insert (propertize (concordd-message--format-timestamp timestamp)
                           'face 'shadow))
        (insert " ")
        (insert (propertize username
                           'face '(:weight bold :foreground "#5865F2")))
        (when edited
          (insert (propertize " (edited)" 'face 'italic)))
        (insert "\n")
        
        ;; Insert message content
        (when (and content (> (length content) 0))
          (let ((content-start (point)))
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
        
        (insert "\n")
        
        ;; Store message ID as text property for the whole message
        (put-text-property start-pos (point)
                          'concordd-message-id (concordd-message-id message)))
    
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

(provide 'concordd-message)
;;; concordd-message.el ends here
