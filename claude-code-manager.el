;;; claude-code-manager.el --- Dashboard for Claude Code instances -*- lexical-binding: t; -*-

;; Author: lishiyu <522583971@qq.com>
;; URL: https://github.com/lsy83971/claude-code-emacs
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (claude-code "0.1"))
;; Keywords: tools, ai

;;; Commentary:
;; A tabulated-list-mode based dashboard for managing Claude Code instances.
;; Features: view all running instances, check activity status, create/kill
;; instances, batch delete, and sync input windows when switching instances.

;;; Code:

(require 'claude-code)
(require 'cl-lib)

(declare-function vterm-send-string "vterm")
(declare-function vterm-send-return "vterm")
(declare-function vterm-copy-mode "vterm")
(declare-function claude-code-input-mode "claude-code-extras")

(defvar claude-code-input-window-height)
(defvar claude-code-input--target)

;;;; Customization

(defgroup claude-code-manager nil
  "Dashboard for managing Claude Code instances."
  :group 'claude-code)

(defcustom claude-code-manager-refresh-interval 2
  "Auto-refresh interval in seconds."
  :type 'number
  :group 'claude-code-manager)

;;;; Internal State

(defvar claude-code-manager--timer nil
  "Timer for auto-refreshing the dashboard.")

(defvar claude-code-manager--marked-buffers nil
  "List of buffer names marked for deletion.")

;;;; Activity Extraction

(defun claude-code-manager--get-activity (buf)
  "Extract current activity from Claude BUF's terminal content."
  (if (not (buffer-live-p buf))
      "dead"
    (let ((proc (get-buffer-process buf)))
      (if (not (and proc (process-live-p proc)))
          "exited"
        (with-current-buffer buf
          (let* ((content (buffer-substring-no-properties
                           (max (point-min) (- (point-max) 500))
                           (point-max)))
                 ;; Remove ANSI escape sequences
                 (clean (replace-regexp-in-string "\033\\[[0-9;]*[a-zA-Z]" "" content))
                 ;; Split into lines, remove empty ones
                 (lines (seq-filter (lambda (s) (not (string-empty-p (string-trim s))))
                                    (split-string clean "\n")))
                 ;; Take last meaningful line
                 (last-line (if lines
                                (string-trim (car (last lines)))
                              "")))
            ;; Truncate for display
            (if (> (length last-line) 40)
                (concat (substring last-line 0 37) "...")
              last-line)))))))

;;;; Entry Generation

(defun claude-code-manager--entries ()
  "Generate entries for the tabulated list."
  (let ((buffers (claude-code--find-all-claude-buffers)))
    (mapcar
     (lambda (buf)
       (let* ((buf-name (buffer-name buf))
              (dir (or (claude-code--extract-directory-from-buffer-name buf-name)
                       ""))
              (instance (or (claude-code--extract-instance-name-from-buffer-name buf-name)
                            "default"))
              (proc (get-buffer-process buf))
              (status (if (and proc (process-live-p proc)) "running" "stopped"))
              (activity (claude-code-manager--get-activity buf))
              (mark (if (member buf-name claude-code-manager--marked-buffers) "D" "")))
         (list buf-name
               (vector mark instance dir status activity))))
     buffers)))

;;;; Refresh

(defun claude-code-manager--refresh ()
  "Refresh the entries in the dashboard."
  (setq tabulated-list-entries (claude-code-manager--entries)))

(defun claude-code-manager--auto-refresh ()
  "Auto-refresh callback; only refreshes if buffer is visible."
  (let ((buf (get-buffer "*Claude Manager*")))
    (when (and buf (get-buffer-window buf t))
      (with-current-buffer buf
        (let ((pos (point)))
          (tabulated-list-revert)
          (goto-char (min pos (point-max))))))))

(defun claude-code-manager--start-timer ()
  "Start the auto-refresh timer."
  (claude-code-manager--stop-timer)
  (setq claude-code-manager--timer
        (run-with-timer claude-code-manager-refresh-interval
                        claude-code-manager-refresh-interval
                        #'claude-code-manager--auto-refresh)))

(defun claude-code-manager--stop-timer ()
  "Stop the auto-refresh timer."
  (when claude-code-manager--timer
    (cancel-timer claude-code-manager--timer)
    (setq claude-code-manager--timer nil)))

;;;; Helpers

(defun claude-code-manager--current-buffer ()
  "Return the Claude buffer for the entry at point."
  (when-let ((entry (tabulated-list-get-id)))
    (get-buffer entry)))

;;;; Interactive Commands

(defun claude-code-manager-goto-instance ()
  "Switch to the Claude instance at point."
  (interactive)
  (if-let ((buf (claude-code-manager--current-buffer)))
      (switch-to-buffer buf)
    (message "Buffer no longer exists; refreshing...")
    (tabulated-list-revert)))

(defun claude-code-manager-create ()
  "Create a new Claude Code instance."
  (interactive)
  (call-interactively #'claude-code-start-in-directory))

(defun claude-code-manager-continue ()
  "Start a Claude instance with --continue."
  (interactive)
  (call-interactively #'claude-code-continue))

(defun claude-code-manager-kill ()
  "Kill the Claude instance at point."
  (interactive)
  (if-let ((buf (claude-code-manager--current-buffer)))
      (progn
        (claude-code--kill-buffer buf)
        (tabulated-list-revert))
    (message "No instance at point")))

(defun claude-code-manager-kill-all ()
  "Kill all Claude instances."
  (interactive)
  (when (yes-or-no-p "Kill ALL Claude instances? ")
    (claude-code-kill-all)
    (tabulated-list-revert)))

(defun claude-code-manager-send-command ()
  "Send a command to the Claude instance at point."
  (interactive)
  (if-let ((buf (claude-code-manager--current-buffer)))
      (let ((cmd (read-string "Command: ")))
        (with-current-buffer buf
          (when (bound-and-true-p vterm-copy-mode)
            (vterm-copy-mode -1))
          (vterm-send-string cmd t)
          (vterm-send-return)))
    (message "No instance at point")))

(defun claude-code-manager-mark-delete ()
  "Mark the instance at point for deletion."
  (interactive)
  (when-let ((id (tabulated-list-get-id)))
    (cl-pushnew id claude-code-manager--marked-buffers :test #'equal)
    (tabulated-list-revert)
    (forward-line 1)))

(defun claude-code-manager-unmark ()
  "Remove deletion mark from instance at point."
  (interactive)
  (when-let ((id (tabulated-list-get-id)))
    (setq claude-code-manager--marked-buffers
          (delete id claude-code-manager--marked-buffers))
    (tabulated-list-revert)
    (forward-line 1)))

(defun claude-code-manager-execute ()
  "Kill all instances marked for deletion."
  (interactive)
  (if (not claude-code-manager--marked-buffers)
      (message "No marked instances")
    (when (yes-or-no-p (format "Kill %d marked instance(s)? "
                               (length claude-code-manager--marked-buffers)))
      (dolist (name claude-code-manager--marked-buffers)
        (when-let ((buf (get-buffer name)))
          (claude-code--kill-buffer buf)))
      (setq claude-code-manager--marked-buffers nil)
      (tabulated-list-revert))))

(defun claude-code-manager-quit ()
  "Quit the Claude Manager dashboard."
  (interactive)
  (quit-window t))

;;;; Keymap

(defvar claude-code-manager-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map (kbd "RET") #'claude-code-manager-goto-instance)
    (define-key map (kbd "o")   #'claude-code-manager-goto-instance)
    (define-key map (kbd "c")   #'claude-code-manager-create)
    (define-key map (kbd "C")   #'claude-code-manager-continue)
    (define-key map (kbd "k")   #'claude-code-manager-kill)
    (define-key map (kbd "K")   #'claude-code-manager-kill-all)
    (define-key map (kbd "s")   #'claude-code-manager-send-command)
    (define-key map (kbd "d")   #'claude-code-manager-mark-delete)
    (define-key map (kbd "u")   #'claude-code-manager-unmark)
    (define-key map (kbd "x")   #'claude-code-manager-execute)
    (define-key map (kbd "q")   #'claude-code-manager-quit)
    map)
  "Keymap for Claude Manager mode.")

;;;; Major Mode

(define-derived-mode claude-code-manager-mode tabulated-list-mode "Claude-Manager"
  "Major mode for managing Claude Code instances.
\\{claude-code-manager-mode-map}"
  (setq tabulated-list-format
        [("" 1 t)
         ("Instance" 20 t)
         ("Directory" 30 t)
         ("Status" 10 t)
         ("Activity" 40 t)])
  (setq tabulated-list-padding 2)
  (setq tabulated-list-sort-key '("Directory" . nil))
  (add-hook 'tabulated-list-revert-hook #'claude-code-manager--refresh nil t)
  (tabulated-list-init-header))

;;;; Entry Point

;;;###autoload
(defun claude-code-manager ()
  "Open the Claude Code instance manager dashboard."
  (interactive)
  (let ((buf (get-buffer-create "*Claude Manager*")))
    (with-current-buffer buf
      (unless (derived-mode-p 'claude-code-manager-mode)
        (claude-code-manager-mode)
        (add-hook 'kill-buffer-hook #'claude-code-manager--stop-timer nil t))
      (setq claude-code-manager--marked-buffers nil)
      (tabulated-list-revert))
    (claude-code-manager--start-timer)
    (pop-to-buffer buf)))

(provide 'claude-code-manager)
;;; claude-code-manager.el ends here
