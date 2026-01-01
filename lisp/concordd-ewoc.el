;;; concordd-ewoc.el --- EWOC utilities for Concordd -*- lexical-binding: t; -*-

;; Copyright (C) 2025 Concordd Project
;; Author: Andrej Novikov
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1"))
;; Keywords: comm, discord

;;; Commentary:

;; This file provides utility functions for working with EWOC
;; (Emacs Widget for Object Collections) in Concordd.

;;; Code:

(require 'ewoc)
(require 'concordd-message)

;;; EWOC Utility Functions

(defun concordd-ewoc-find-message (ewoc message-id)
  "Find node in EWOC with MESSAGE-ID.
Returns the first matching node, or nil if not found."
  (catch 'found
    (ewoc-map (lambda (data)
                (when (and (concordd-message-p data)
                          (string= (concordd-message-id data) message-id))
                  (throw 'found data))
                nil)
              ewoc)
    nil))

(defun concordd-ewoc-find-message-node (ewoc message-id)
  "Find EWOC node containing message with MESSAGE-ID.
Returns the node itself, not just the data."
  (catch 'found
    (ewoc-map (lambda (data)
                (when (and (concordd-message-p data)
                          (string= (concordd-message-id data) message-id))
                  (throw 'found (ewoc-locate ewoc (point))))
                nil)
              ewoc)
    nil))

(defun concordd-ewoc-update-message (ewoc message-id update-fn)
  "Update message with MESSAGE-ID in EWOC using UPDATE-FN.
UPDATE-FN is called with the message struct and should modify it in place.
The node is invalidated after the update, triggering a re-render."
  (when-let ((node (concordd-ewoc-find-message-node ewoc message-id)))
    (let ((msg (ewoc-data node)))
      (funcall update-fn msg)
      (ewoc-invalidate ewoc node))))

(defun concordd-ewoc-delete-message (ewoc message-id)
  "Delete message with MESSAGE-ID from EWOC."
  (when-let ((node (concordd-ewoc-find-message-node ewoc message-id)))
    (ewoc-delete ewoc node)))

(defun concordd-ewoc-insert-message-sorted (ewoc message)
  "Insert MESSAGE into EWOC in timestamp order.
Assumes messages are generally in chronological order and searches from end."
  (let ((timestamp (concordd-message-timestamp message))
        (node (ewoc-nth ewoc -1)))  ; Start from last node
    
    ;; Find insertion point by walking backward
    (while (and node
                (let ((data (ewoc-data node)))
                  (and (concordd-message-p data)
                       (string< timestamp (concordd-message-timestamp data)))))
      (setq node (ewoc-prev ewoc node)))
    
    ;; Insert after found node (or at beginning if node is nil)
    (if node
        (ewoc-enter-after ewoc node message)
      (ewoc-enter-first ewoc message))))

(defun concordd-ewoc-get-all-messages (ewoc)
  "Get all message structs from EWOC as a list."
  (let (messages)
    (ewoc-map (lambda (data)
                (when (concordd-message-p data)
                  (push data messages))
                nil)
              ewoc)
    (nreverse messages)))

(defun concordd-ewoc-goto-message (ewoc message-id)
  "Move point to message with MESSAGE-ID in EWOC.
Returns t if found, nil otherwise."
  (when-let ((node (concordd-ewoc-find-message-node ewoc message-id)))
    (ewoc-goto-node ewoc node)
    t))

(provide 'concordd-ewoc)
;;; concordd-ewoc.el ends here
