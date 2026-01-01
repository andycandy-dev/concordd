;;; concordd-format.el --- Message formatting for Concordd -*- lexical-binding: t; -*-

;; Copyright (C) 2025 Concordd Project
;; Author: Andrej Novikov
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1") (markdown-mode "2.5"))
;; Keywords: comm, discord

;;; Commentary:

;; This file provides minimal message formatting for Concordd.
;; It handles Discord-specific mentions (users, roles, channels),
;; while markdown-view-mode handles all standard markdown formatting.

;;; Code:

(require 'cl-lib)

;;; Faces

(defface concordd-mention-user
  '((t :foreground "#5865F2" :weight bold))
  "Face for user mentions."
  :group 'concordd)

(defface concordd-mention-role
  '((t :foreground "#f47fff" :weight bold))
  "Face for role mentions."
  :group 'concordd)

(defface concordd-mention-channel
  '((t :foreground "#5865F2" :weight bold))
  "Face for channel mentions."
  :group 'concordd)

(defface concordd-mention-unresolved
  '((t :inherit shadow :slant italic))
  "Face for unresolved mentions."
  :group 'concordd)

;;; Cache variables

(defvar concordd-format-guild-members nil
  "Hash table: guild-id -> list of member plists.")

(defvar concordd-format-guild-roles nil
  "Hash table: guild-id -> list of role plists.")

(defvar concordd-format-channels nil
  "Hash table: guild-id -> list of channel plists.")

;;; Mention resolution

(defun concordd-format--resolve-user (user-id guild-id)
  "Resolve USER-ID to display name in GUILD-ID."
  (when-let* ((members (and concordd-format-guild-members
                           (gethash guild-id concordd-format-guild-members)))
              (member (cl-find-if
                      (lambda (m)
                        (string= (plist-get (plist-get m :user) :id) user-id))
                      members)))
    (let* ((user (plist-get member :user))
           (nick (plist-get member :nick))
           (username (plist-get user :username)))
      (or nick username))))

(defun concordd-format--resolve-role (role-id guild-id)
  "Resolve ROLE-ID to role info in GUILD-ID.
Returns (name . color) or nil."
  (when-let* ((roles (and concordd-format-guild-roles
                         (gethash guild-id concordd-format-guild-roles)))
              (role (cl-find-if
                    (lambda (r) (string= (plist-get r :id) role-id))
                    roles)))
    (cons (plist-get role :name)
          (plist-get role :color))))

(defun concordd-format--resolve-channel (channel-id guild-id)
  "Resolve CHANNEL-ID to channel name in GUILD-ID."
  (when-let* ((channels (and concordd-format-channels
                            (gethash guild-id concordd-format-channels)))
              (channel (cl-find-if
                       (lambda (c) (string= (plist-get c :id) channel-id))
                       channels)))
    (plist-get channel :name)))

;;; Pre-processing: Replace mentions before markdown

(defun concordd-format-preprocess-mentions (content guild-id)
  "Replace Discord mention syntax with readable text in CONTENT.
This should be called BEFORE markdown-view-mode processing."
  (let ((result content))
    ;; User mentions: <@123> or <@!123> -> @Username
    (setq result (replace-regexp-in-string
                  "<@!?\\([0-9]+\\)>"
                  (lambda (match)
                    (let* ((user-id (match-string 1 match))
                           (name (concordd-format--resolve-user user-id guild-id)))
                      (if name
                          (format "@%s" name)
                        match)))
                  result t t))
    
    ;; Role mentions: <@&456> -> @RoleName
    (setq result (replace-regexp-in-string
                  "<@&\\([0-9]+\\)>"
                  (lambda (match)
                    (let* ((role-id (match-string 1 match))
                           (role-info (concordd-format--resolve-role role-id guild-id)))
                      (if role-info
                          (format "@%s" (car role-info))
                        match)))
                  result t t))
    
    ;; Channel mentions: <#789> -> #channel-name
    (setq result (replace-regexp-in-string
                  "<#\\([0-9]+\\)>"
                  (lambda (match)
                    (let* ((channel-id (match-string 1 match))
                           (name (concordd-format--resolve-channel channel-id guild-id)))
                      (if name
                          (format "#%s" name)
                        match)))
                  result t t))
    
    result))

;;; Post-processing: Add faces to mentions after markdown

(defun concordd-format-postprocess-mentions (guild-id)
  "Add faces to resolved mentions in current buffer.
This should be called AFTER markdown-view-mode has processed the buffer."
  ;; User mentions: @Username
  (save-excursion
    (goto-char (point-min))
    (while (re-search-forward "@\\([A-Za-z0-9_-]+\\)" nil t)
      (add-face-text-property (match-beginning 0) (match-end 0)
                             'concordd-mention-user)))
  
  ;; Channel mentions: #channel-name
  (save-excursion
    (goto-char (point-min))
    (while (re-search-forward "#\\([a-z0-9_-]+\\)" nil t)
      (add-face-text-property (match-beginning 0) (match-end 0)
                             'concordd-mention-channel)))
  
  ;; Unresolved mentions: <@123>, <@&456>, <#789>
  (save-excursion
    (goto-char (point-min))
    (while (re-search-forward "<[@#][@&!]?[0-9]+>" nil t)
      (add-face-text-property (match-beginning 0) (match-end 0)
                             'concordd-mention-unresolved))))

;;; Cache management

(defun concordd-format-set-guild-cache (guild-id members roles channels)
  "Set cache for GUILD-ID with MEMBERS, ROLES, and CHANNELS."
  (unless concordd-format-guild-members
    (setq concordd-format-guild-members (make-hash-table :test 'equal)))
  (unless concordd-format-guild-roles
    (setq concordd-format-guild-roles (make-hash-table :test 'equal)))
  (unless concordd-format-channels
    (setq concordd-format-channels (make-hash-table :test 'equal)))
  
  (when members
    (puthash guild-id members concordd-format-guild-members))
  (when roles
    (puthash guild-id roles concordd-format-guild-roles))
  (when channels
    (puthash guild-id channels concordd-format-channels)))

(provide 'concordd-format)
;;; concordd-format.el ends here
