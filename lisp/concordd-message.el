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
(require 'url)
;; concordd-format is loaded on-demand for formatting
(declare-function concordd-format-preprocess-mentions "concordd-format")
(declare-function concordd-format-postprocess-mentions "concordd-format")
(declare-function concordd-ui-v2-refresh "concordd-ui-v2")
(declare-function concordd-ewoc-find-message "concordd-ewoc")
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

(defcustom concordd-message-show-images nil
  "Whether to display attached images inline in messages.
When non-nil, images are downloaded and displayed as small thumbnails."
  :type 'boolean
  :group 'concordd)

(defcustom concordd-message-image-max-height 150
  "Maximum height in pixels for inline image thumbnails."
  :type 'integer
  :group 'concordd)

(defcustom concordd-message-image-max-width 300
  "Maximum width in pixels for inline image thumbnails."
  :type 'integer
  :group 'concordd)

(defcustom concordd-message-external-viewer-command "xdg-open %u"
  "External command template for opening attachments.
Placeholders:
  %u - URL of the attachment
  %f - Filename of the attachment
Examples:
  \"open %u\"          - macOS default opener
  \"xdg-open %u\"      - Linux default opener
  \"wget %u -O %f\"    - Download file"
  :type 'string
  :group 'concordd)

(defcustom concordd-message-external-video-command nil
  "External command template for opening video attachments.
If non-nil, overrides `concordd-message-external-viewer-command` for videos.
Placeholders:
  %u - URL of the attachment
  %f - Filename of the attachment
Examples:
  \"mpv %u\"           - Open with mpv
  \"vlc %u\"           - Open with VLC
  \"iina %u\"          - Open with IINA (macOS)"
  :type '(choice (const :tag "Use general viewer command" nil)
                 (string :tag "Video-specific command"))
  :group 'concordd)

;;; Variables

(defvar concordd-message-image-cache (make-hash-table :test 'equal)
  "Cache of downloaded images. Maps URL to image data.")

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
             (attachments (concordd-message-attachments message))
             (embeds (concordd-message-embeds message))
             (thread-id (concordd-message-thread-id message))
             (start-pos (point))
             (show-header (or edited reactions thread-id attachments
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
        (when attachments
          (concordd-message--format-attachments attachments embeds))
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

;;; Image Handling

(defun concordd-message--is-image-url (url)
  "Check if URL points to an image file."
  (and url
       (string-match-p "\\.\\(png\\|jpe?g\\|gif\\|webp\\|bmp\\)\\(?:\\?.*\\)?$"
                      (downcase url))))

(defun concordd-message--is-video-content-type (content-type)
  "Check if CONTENT-TYPE is a video."
  (and content-type
       (string-match-p "^video/" content-type)))

(defun concordd-message--find-thumbnail-for-url (url embeds)
  "Find thumbnail URL in EMBEDS that matches attachment URL.
Returns the thumbnail URL if found, nil otherwise."
  (when embeds
    (catch 'found
      (dolist (embed embeds)
        ;; Check if embed's video/image URL matches attachment URL
        (let ((embed-video-url (plist-get (plist-get embed :video) :url))
              (embed-image-url (plist-get (plist-get embed :image) :url))
              (embed-url (plist-get embed :url)))
          ;; If this embed references our attachment, return its thumbnail
          (when (or (and embed-video-url (string= embed-video-url url))
                   (and embed-image-url (string= embed-image-url url))
                   (and embed-url (string= embed-url url)))
            (when-let ((thumbnail (plist-get embed :thumbnail)))
              (throw 'found (plist-get thumbnail :url)))))))))


(defun concordd-message--download-image (url callback)
  "Download image from URL and call CALLBACK with image data.
If image is in cache, use cached version. Otherwise download async."
  (if-let ((cached (gethash url concordd-message-image-cache)))
      (funcall callback cached)
    (url-retrieve
     url
     (lambda (status callback url)
       (if (plist-get status :error)
           (message "Failed to download image: %s" url)
         (goto-char (point-min))
         (when (re-search-forward "\n\n" nil t)
           (let ((image-data (buffer-substring (point) (point-max))))
             (puthash url image-data concordd-message-image-cache)
             (funcall callback image-data)))))
     (list callback url)
     t)))

(defun concordd-message--create-image-thumbnail (image-data)
  "Create a thumbnail image from IMAGE-DATA."
  (when image-data
    (let ((img (create-image image-data nil t)))
      (when img
        (let* ((size (image-size img t))
               (width (car size))
               (height (cdr size))
               (scale-w (/ (float concordd-message-image-max-width) width))
               (scale-h (/ (float concordd-message-image-max-height) height))
               (scale (min scale-w scale-h 1.0)))
          (create-image image-data nil t
                       :max-width concordd-message-image-max-width
                       :max-height concordd-message-image-max-height
                       :scale scale))))))

(defun concordd-message--filename-from-url (url)
  "Extract filename from URL, stripping query parameters."
  (when url
    (let* ((path (url-filename (url-generic-parse-url url)))
           (filename (if (string-match "/\\([^/]+\\)$" path)
                        (match-string 1 path)
                      "unknown")))
      ;; Strip query parameters from filename
      (if (string-match "\\([^?]+\\)" filename)
          (match-string 1 filename)
        filename))))

(defun concordd-message--insert-attachment (attachment embeds)
  "Insert ATTACHMENT into buffer, using EMBEDS for thumbnail URLs.
ATTACHMENT can be either a URL string or a plist.
If it's an image/video and images are enabled, display inline thumbnail.
Otherwise, show a link."
  (let* ((url (if (stringp attachment)
                  attachment
                (plist-get attachment :url)))
         (filename (if (stringp attachment)
                      (concordd-message--filename-from-url attachment)
                    (or (plist-get attachment :filename)
                        (concordd-message--filename-from-url url))))
         (content-type (unless (stringp attachment)
                        (plist-get attachment :contentType)))
         (is-image (or (concordd-message--is-image-url url)
                      (and content-type
                           (string-match-p "^image/" content-type))))
         (is-video (concordd-message--is-video-content-type content-type))
         ;; Try to find thumbnail from embeds
         (thumbnail-url (concordd-message--find-thumbnail-for-url url embeds)))
    (cond
     ;; Video with thumbnail
     ((and is-video thumbnail-url concordd-message-show-images)
      (concordd-message--insert-image-attachment thumbnail-url filename))
     ;; Video without thumbnail
     (is-video
      (concordd-message--insert-link-attachment url filename "Video"))
     ;; Image with embed thumbnail (prefer embed thumbnail for optimization)
     ((and is-image thumbnail-url concordd-message-show-images)
      (concordd-message--insert-image-attachment thumbnail-url filename))
     ;; Regular image
     ((and is-image concordd-message-show-images)
      (concordd-message--insert-image-attachment url filename))
     ;; Fallback to link
     (t
      (concordd-message--insert-link-attachment url filename)))))

(defun concordd-message--insert-image-attachment (url filename)
  "Insert image attachment from URL with FILENAME as thumbnail."
  ;; Check if image is already in cache
  (if-let ((cached (gethash url concordd-message-image-cache)))
      ;; Image in cache - insert immediately
      (if-let ((img (concordd-message--create-image-thumbnail cached)))
          (let ((img-start (point)))
            (insert-image img)
            (insert " ")
            (put-text-property img-start (point) 'concordd-image-url url)
            (put-text-property img-start (point) 'concordd-attachment-filename filename)
            (put-text-property img-start (point) 'concordd-attachment-type "image"))
        ;; Failed to create thumbnail - show as link
        (insert (propertize (format "[Attachment: %s]" filename)
                           'face 'link
                           'concordd-attachment-url url
                           'concordd-attachment-filename filename
                           'concordd-attachment-type "image"))
        (insert " "))
    ;; Not in cache - show placeholder and download in background
    (insert (propertize (format "[Image: %s]" filename)
                       'face 'link
                       'concordd-image-url url
                       'concordd-attachment-filename filename
                       'concordd-attachment-type "image"))
    (insert " ")
    ;; Start download in background (will be cached for next refresh)
    (concordd-message--download-image url #'ignore)))

(defun concordd-message--insert-link-attachment (url filename &optional type)
  "Insert attachment as clickable link with URL and FILENAME.
TYPE is an optional label like \"Video\" or \"Attachment\"."
  (let ((label (or type "Attachment")))
    (insert (propertize (format "[%s: %s]" label filename)
                       'face 'link
                       'concordd-attachment-url url
                       'concordd-attachment-filename filename
                       'concordd-attachment-type (downcase (or type "attachment"))))
    (insert " ")))

(defun concordd-message--format-attachments (attachments embeds)
  "Format ATTACHMENTS list for display, using EMBEDS for thumbnails.
Returns nil if no attachments or if images shouldn't be shown."
  (when (and attachments (> (length attachments) 0))
    (let ((start (point)))
      (insert "\n")
      (dolist (attachment attachments)
        (concordd-message--insert-attachment attachment embeds))
      (insert "\n"))))

;;; External Viewer

(defun concordd-message--expand-command-template (template url filename)
  "Expand TEMPLATE replacing %u with URL and %f with FILENAME."
  (let ((result template))
    (setq result (replace-regexp-in-string "%u" (shell-quote-argument url) result t t))
    (setq result (replace-regexp-in-string "%f" (shell-quote-argument filename) result t t))
    result))

(defun concordd-message-open-externally (url filename &optional attachment-type)
  "Open URL with FILENAME using external viewer command.
ATTACHMENT-TYPE can be \"video\", \"image\", etc. to select specific viewer."
  (let* ((command-template (if (and (equal attachment-type "video")
                                   concordd-message-external-video-command)
                              concordd-message-external-video-command
                            concordd-message-external-viewer-command))
         (command (concordd-message--expand-command-template
                  command-template
                  url
                  filename)))
    (message "Opening: %s" filename)
    (start-process-shell-command "concordd-viewer" nil command)))

;;; Preview/Open Attachment

(defun concordd-message-preview-image-at-point ()
  "Preview/open the attachment at point.
For images: preview in Emacs buffer
For videos/other files: open with external viewer"
  (interactive)
  (let ((url (or (get-text-property (point) 'concordd-image-url)
                (get-text-property (point) 'concordd-attachment-url)))
        (filename (get-text-property (point) 'concordd-attachment-filename))
        (att-type (get-text-property (point) 'concordd-attachment-type)))
    (cond
     ;; Image - preview in Emacs
     ((and url (or (concordd-message--is-image-url url)
                  (equal att-type "image")))
      (concordd-message--preview-image-internal url))

     ;; Video or other attachment - open externally
     ((and url filename)
      (concordd-message-open-externally url filename att-type))

     ;; No attachment found
     (t
      (message "No attachment at point")))))

(defun concordd-message--preview-image-internal (url)
  "Preview image from URL in internal Emacs buffer."
  (concordd-message--download-image
   url
   (lambda (image-data)
     (let ((buf (get-buffer-create "*Concordd Image Preview*")))
       (with-current-buffer buf
         (let ((inhibit-read-only t))
           (erase-buffer)
           (if-let ((img (create-image image-data nil t)))
               (progn
                 (insert-image img)
                 (insert "\n\n")
                 (insert (propertize url 'face 'link))
                 (goto-char (point-min)))
             (insert (propertize "Failed to create image from data\n\n" 'face 'error))
             (insert (propertize url 'face 'link)))
           (special-mode)
           (local-set-key (kbd "q") 'quit-window)))
       (pop-to-buffer buf)))))

;;; Toggle Command

(defun concordd-message-toggle-images ()
  "Toggle inline image display in messages."
  (interactive)
  (setq concordd-message-show-images (not concordd-message-show-images))
  (message "Inline images: %s" (if concordd-message-show-images "enabled" "disabled"))
  ;; Refresh current buffer if in a concordd channel
  (when (eq major-mode 'concordd-ui-v2-channel-mode)
    (concordd-ui-v2-refresh)))

;;; Debug Helpers

(defun concordd-message-inspect-at-point ()
  "Inspect the raw message data at point."
  (interactive)
  (when-let ((msg-id (get-text-property (point) 'concordd-message-id)))
    (let ((msg (concordd-ewoc-find-message concordd-message-ewoc msg-id)))
      (when msg
        (let ((buf (get-buffer-create "*Concordd Message Inspector*")))
          (with-current-buffer buf
            (let ((inhibit-read-only t))
              (erase-buffer)
              (insert (format "Message ID: %s\n\n" (concordd-message-id msg)))
              (insert (format "Attachments (%d):\n" (length (concordd-message-attachments msg))))
              (dolist (att (concordd-message-attachments msg))
                (insert (format "  - %s\n" (pp-to-string att))))
              (insert (format "\nEmbeds (%d):\n" (length (concordd-message-embeds msg))))
              (dolist (emb (concordd-message-embeds msg))
                (insert (format "  - %s\n" (pp-to-string emb))))
              (goto-char (point-min)))
            (special-mode)
            (local-set-key (kbd "q") 'quit-window))
          (pop-to-buffer buf))))))

;;; Cache Management

;;;###autoload
(defun concordd-message-clear-image-cache ()
  "Clear the image cache to free memory.
Useful if you've browsed many channels with images."
  (interactive)
  (let ((count (hash-table-count concordd-message-image-cache)))
    (clrhash concordd-message-image-cache)
    (message "Cleared %d cached images" count)))

;;;###autoload
(defun concordd-message-image-cache-info ()
  "Show information about the image cache."
  (interactive)
  (let* ((count (hash-table-count concordd-message-image-cache))
         (total-size 0))
    (maphash (lambda (_url data)
               (setq total-size (+ total-size (length data))))
             concordd-message-image-cache)
    (message "Image cache: %d images, ~%.1f MB"
             count
             (/ total-size 1048576.0))))

(provide 'concordd-message)
;;; concordd-message.el ends here
