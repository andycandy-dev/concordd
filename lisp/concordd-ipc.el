;;; concordd-ipc.el --- IPC layer for Concordd -*- lexical-binding: t; -*-

;; Copyright (C) 2025 Concordd Project

;;; Commentary:

;; This file implements the JSON-RPC 2.0 communication layer with the
;; concordd daemon over Unix domain socket.

;;; Code:

(require 'json)
(require 'cl-lib)

;;; Internal variables

(defvar concordd-ipc--connection nil
  "Network process for the daemon connection.")

(defvar concordd-ipc--request-id 0
  "Counter for JSON-RPC request IDs.")

(defvar concordd-ipc--pending-requests (make-hash-table :test 'equal)
  "Hash table of pending requests awaiting responses.
Keys are request IDs, values are callback functions.")

(defvar concordd-ipc--event-handlers (make-hash-table :test 'equal)
  "Hash table of event handlers for push notifications.
Keys are method names (strings), values are lists of callback functions.")

(defvar concordd-ipc--buffer nil
  "Buffer for accumulating incoming data.")

;;; Connection management

(defun concordd-ipc-connect (socket-path)
  "Connect to the concordd daemon at SOCKET-PATH."
  (when concordd-ipc--connection
    (error "Already connected to Concordd daemon"))
  
  (unless (file-exists-p socket-path)
    (error "Socket not found: %s. Is concordd daemon running?" socket-path))
  
  (setq concordd-ipc--connection
        (make-network-process
         :name "concordd-daemon"
         :family 'local
         :remote socket-path
         :coding 'utf-8
         :filter #'concordd-ipc--filter
         :sentinel #'concordd-ipc--sentinel))
  
  (setq concordd-ipc--buffer "")
  (message "Connected to Concordd daemon at %s" socket-path))

(defun concordd-ipc-disconnect ()
  "Disconnect from the concordd daemon."
  (when concordd-ipc--connection
    (delete-process concordd-ipc--connection)
    (setq concordd-ipc--connection nil)
    (setq concordd-ipc--buffer "")
    (clrhash concordd-ipc--pending-requests)
    (message "Disconnected from Concordd daemon")))

(defun concordd-ipc-connected-p ()
  "Return non-nil if connected to the daemon."
  (and concordd-ipc--connection
       (process-live-p concordd-ipc--connection)))

;;; JSON-RPC implementation

(defun concordd-ipc--next-id ()
  "Generate next request ID."
  (cl-incf concordd-ipc--request-id))

(defun concordd-ipc-send-request (method params callback)
  "Send a JSON-RPC request to the daemon.
METHOD is the RPC method name.
PARAMS is a plist of parameters.
CALLBACK is called with the result on success, or nil on error."
  (unless (concordd-ipc-connected-p)
    (error "Not connected to Concordd daemon"))
  
  (let* ((id (concordd-ipc--next-id))
         (request `((jsonrpc . "2.0")
                   (id . ,id)
                   (method . ,method)
                   (params . ,params)))
         (json (concat (json-encode request) "\n")))
    
    (when (bound-and-true-p concordd-log-messages)
      (message "→ %s" json))
    
    (puthash id callback concordd-ipc--pending-requests)
    (process-send-string concordd-ipc--connection json)))

(defun concordd-ipc--filter (proc string)
  "Process filter for incoming data from daemon.
PROC is the network process.
STRING is the incoming data."
  (condition-case err
      (progn
        (setq concordd-ipc--buffer (concat concordd-ipc--buffer string))
        
        ;; Process complete lines (messages end with \n)
        (while (string-match "\n" concordd-ipc--buffer)
          (let* ((line-end (match-beginning 0))
                 (line (substring concordd-ipc--buffer 0 line-end)))
            (setq concordd-ipc--buffer (substring concordd-ipc--buffer (1+ line-end)))
            (concordd-ipc--handle-message line))))
    (quit
     ;; User quit, don't show error message
     nil)
    (error
     (message "Error in concordd IPC filter: %s" err))))

(defun concordd-ipc--handle-message (line)
  "Handle a complete JSON-RPC message from the daemon.
LINE is the JSON string."
  (when (bound-and-true-p concordd-log-messages)
    (message "← %s" line))
  
  (condition-case err
      (let ((msg (json-parse-string line :object-type 'plist :array-type 'list)))
        (if (plist-get msg :id)
            ;; Response
            (concordd-ipc--handle-response msg)
          ;; Notification
          (concordd-ipc--handle-notification msg)))
    (quit
     ;; User quit, don't show error message
     nil)
    (error
     (message "Error parsing JSON-RPC message: %s" err))))

(defun concordd-ipc--handle-response (msg)
  "Handle a JSON-RPC response.
MSG is the parsed response plist."
  (let* ((id (plist-get msg :id))
         (callback (gethash id concordd-ipc--pending-requests)))
    (remhash id concordd-ipc--pending-requests)
    
    (when callback
      (if (plist-get msg :error)
          (let ((error-obj (plist-get msg :error)))
            (message "Concordd RPC error: %s" (plist-get error-obj :message))
            (funcall callback nil))
        (condition-case err
            (funcall callback (plist-get msg :result))
          (quit
           ;; User quit during callback, don't propagate
           nil)
          (error
           (message "Error in RPC callback: %s" err)))))))

(defun concordd-ipc--handle-notification (msg)
  "Handle a JSON-RPC notification (push event).
MSG is the parsed notification plist."
  (let* ((method (plist-get msg :method))
         (params (plist-get msg :params))
         (handlers (gethash method concordd-ipc--event-handlers)))
    
    (when (bound-and-true-p concordd-log-messages)
      (message "Event: %s" method))
    
    (dolist (handler handlers)
      (condition-case err
          (funcall handler params)
        (quit
         ;; User quit during handler, don't propagate
         nil)
        (error
         (message "Error in event handler for %s: %s" method err))))))

(defun concordd-ipc--sentinel (proc event)
  "Process sentinel for connection status.
PROC is the network process.
EVENT describes the status change."
  (unless (process-live-p proc)
    (message "Disconnected from Concordd daemon: %s" (string-trim event))
    (setq concordd-ipc--connection nil)))

;;; Event handling

(defun concordd-ipc-on (event handler)
  "Register an event handler.
EVENT is the event name (symbol or string).
HANDLER is a function that takes a params plist."
  (let* ((event-name (if (symbolp event) (symbol-name event) event))
         (handlers (gethash event-name concordd-ipc--event-handlers)))
    (puthash event-name (cons handler handlers) concordd-ipc--event-handlers)))

(defun concordd-ipc-off (event &optional handler)
  "Unregister event handlers.
EVENT is the event name (symbol or string).
If HANDLER is nil, remove all handlers for EVENT.
Otherwise, remove only that HANDLER."
  (let ((event-name (if (symbolp event) (symbol-name event) event)))
    (if handler
        (let ((handlers (gethash event-name concordd-ipc--event-handlers)))
          (puthash event-name (delq handler handlers) concordd-ipc--event-handlers))
      (remhash event-name concordd-ipc--event-handlers))))

(provide 'concordd-ipc)

;;; concordd-ipc.el ends here
