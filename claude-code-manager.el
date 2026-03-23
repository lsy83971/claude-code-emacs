;;; claude-code-manager.el --- Dashboard for Claude Code instances -*- lexical-binding: t; -*-

;; Author: lishiyu <522583971@qq.com>
;; URL: https://github.com/lsy83971/claude-code-emacs
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is NOT part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; A tabulated-list-mode based dashboard for managing Claude Code instances.
;; Features: view all running instances, check activity status, create/kill
;; instances, batch delete, and sync input windows when switching instances.
;;
;; This file is part of the `claude-code-extras' package.

;;; Code:

(require 'claude-code)
(require 'cl-lib)

(declare-function vterm-send-string "vterm")
(declare-function vterm-send-return "vterm")
(declare-function vterm-copy-mode "vterm")
(declare-function claude-code-extras-input-mode "claude-code-extras")
(declare-function claude-code--find-all-claude-buffers "claude-code")
(declare-function claude-code--extract-directory-from-buffer-name "claude-code")
(declare-function claude-code--extract-instance-name-from-buffer-name "claude-code")
(declare-function claude-code--kill-buffer "claude-code")
(declare-function claude-code-start-in-directory "claude-code")
(declare-function claude-code-continue "claude-code")
(declare-function claude-code-kill-all "claude-code")

(defvar claude-code-extras-input-window-height)
(defvar claude-code-extras-input--target)
(defvar vterm-copy-mode)

;;;; Customization

(defgroup claude-code-extras-manager nil
  "Dashboard for managing Claude Code instances."
  :group 'claude-code-extras)

(defcustom claude-code-extras-manager-refresh-interval 2
  "Auto-refresh interval in seconds."
  :type 'number
  :group 'claude-code-extras-manager)

;;;; Internal State

(defvar claude-code-extras-manager--timer nil
  "Timer for auto-refreshing the dashboard.")

(defvar claude-code-extras-manager--marked-buffers nil
  "List of buffer names marked for deletion.")

;;;; Activity Extraction

(defun claude-code-extras-manager--get-activity (buf)
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
                 (clean (replace-regexp-in-string
                         "\033\\[[0-9;]*[a-zA-Z]" "" content))
                 (lines (seq-filter
                         (lambda (s) (not (string-empty-p (string-trim s))))
                         (split-string clean "\n")))
                 (last-line (if lines
                                (string-trim (car (last lines)))
                              "")))
            (if (> (length last-line) 40)
                (concat (substring last-line 0 37) "...")
              last-line)))))))

;;;; Entry Generation

(defun claude-code-extras-manager--entries ()
  "Generate entries for the tabulated list."
  (let ((buffers (claude-code--find-all-claude-buffers)))
    (mapcar
     (lambda (buf)
       (let* ((buf-name (buffer-name buf))
              (dir (or (claude-code--extract-directory-from-buffer-name
                        buf-name)
                       ""))
              (instance (or (claude-code--extract-instance-name-from-buffer-name
                             buf-name)
                            "default"))
              (proc (get-buffer-process buf))
              (status (if (and proc (process-live-p proc))
                          "running" "stopped"))
              (activity (claude-code-extras-manager--get-activity buf))
              (mark (if (member buf-name
                                claude-code-extras-manager--marked-buffers)
                        "D" "")))
         (list buf-name
               (vector mark instance dir status activity))))
     buffers)))

;;;; Refresh

(defun claude-code-extras-manager--refresh ()
  "Refresh the entries in the dashboard."
  (setq tabulated-list-entries (claude-code-extras-manager--entries)))

(defun claude-code-extras-manager--auto-refresh ()
  "Auto-refresh callback; only refreshes if buffer is visible."
  (let ((buf (get-buffer "*Claude Manager*")))
    (when (and buf (get-buffer-window buf t))
      (with-current-buffer buf
        (let ((pos (point)))
          (tabulated-list-revert)
          (goto-char (min pos (point-max))))))))

(defun claude-code-extras-manager--start-timer ()
  "Start the auto-refresh timer."
  (claude-code-extras-manager--stop-timer)
  (setq claude-code-extras-manager--timer
        (run-with-timer claude-code-extras-manager-refresh-interval
                        claude-code-extras-manager-refresh-interval
                        #'claude-code-extras-manager--auto-refresh)))

(defun claude-code-extras-manager--stop-timer ()
  "Stop the auto-refresh timer."
  (when claude-code-extras-manager--timer
    (cancel-timer claude-code-extras-manager--timer)
    (setq claude-code-extras-manager--timer nil)))

;;;; Helpers

(defun claude-code-extras-manager--current-buffer ()
  "Return the Claude buffer for the entry at point."
  (when-let ((entry (tabulated-list-get-id)))
    (get-buffer entry)))

;;;; Interactive Commands

(defun claude-code-extras-manager-goto-instance ()
  "Switch to the Claude instance at point."
  (interactive)
  (if-let ((buf (claude-code-extras-manager--current-buffer)))
      (switch-to-buffer buf)
    (message "Buffer no longer exists; refreshing...")
    (tabulated-list-revert)))

(defun claude-code-extras-manager-create ()
  "Create a new Claude Code instance."
  (interactive)
  (call-interactively #'claude-code-start-in-directory))

(defun claude-code-extras-manager-continue ()
  "Start a Claude instance with --continue."
  (interactive)
  (call-interactively #'claude-code-continue))

(defun claude-code-extras-manager-kill ()
  "Kill the Claude instance at point."
  (interactive)
  (if-let ((buf (claude-code-extras-manager--current-buffer)))
      (progn
        (claude-code--kill-buffer buf)
        (tabulated-list-revert))
    (message "No instance at point")))

(defun claude-code-extras-manager-kill-all ()
  "Kill all Claude instances."
  (interactive)
  (when (yes-or-no-p "Kill ALL Claude instances? ")
    (claude-code-kill-all)
    (tabulated-list-revert)))

(defun claude-code-extras-manager-send-command ()
  "Send a command to the Claude instance at point."
  (interactive)
  (if-let ((buf (claude-code-extras-manager--current-buffer)))
      (let ((cmd (read-string "Command: ")))
        (with-current-buffer buf
          (when (bound-and-true-p vterm-copy-mode)
            (vterm-copy-mode -1))
          (vterm-send-string cmd t)
          (vterm-send-return)))
    (message "No instance at point")))

(defun claude-code-extras-manager-mark-delete ()
  "Mark the instance at point for deletion."
  (interactive)
  (when-let ((id (tabulated-list-get-id)))
    (cl-pushnew id claude-code-extras-manager--marked-buffers :test #'equal)
    (tabulated-list-revert)
    (forward-line 1)))

(defun claude-code-extras-manager-unmark ()
  "Remove deletion mark from instance at point."
  (interactive)
  (when-let ((id (tabulated-list-get-id)))
    (setq claude-code-extras-manager--marked-buffers
          (delete id claude-code-extras-manager--marked-buffers))
    (tabulated-list-revert)
    (forward-line 1)))

(defun claude-code-extras-manager-execute ()
  "Kill all instances marked for deletion."
  (interactive)
  (if (not claude-code-extras-manager--marked-buffers)
      (message "No marked instances")
    (when (yes-or-no-p
           (format "Kill %d marked instance(s)? "
                   (length claude-code-extras-manager--marked-buffers)))
      (dolist (name claude-code-extras-manager--marked-buffers)
        (when-let ((buf (get-buffer name)))
          (claude-code--kill-buffer buf)))
      (setq claude-code-extras-manager--marked-buffers nil)
      (tabulated-list-revert))))

(defun claude-code-extras-manager-quit ()
  "Quit the Claude Manager dashboard."
  (interactive)
  (quit-window t))

;;;; Keymap

(defvar claude-code-extras-manager-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map (kbd "RET") #'claude-code-extras-manager-goto-instance)
    (define-key map (kbd "o")   #'claude-code-extras-manager-goto-instance)
    (define-key map (kbd "c")   #'claude-code-extras-manager-create)
    (define-key map (kbd "C")   #'claude-code-extras-manager-continue)
    (define-key map (kbd "k")   #'claude-code-extras-manager-kill)
    (define-key map (kbd "K")   #'claude-code-extras-manager-kill-all)
    (define-key map (kbd "s")   #'claude-code-extras-manager-send-command)
    (define-key map (kbd "d")   #'claude-code-extras-manager-mark-delete)
    (define-key map (kbd "u")   #'claude-code-extras-manager-unmark)
    (define-key map (kbd "x")   #'claude-code-extras-manager-execute)
    (define-key map (kbd "q")   #'claude-code-extras-manager-quit)
    map)
  "Keymap for `claude-code-extras-manager-mode'.")

;;;; Major Mode

(define-derived-mode claude-code-extras-manager-mode tabulated-list-mode
  "Claude-Manager"
  "Major mode for managing Claude Code instances.
\\{claude-code-extras-manager-mode-map}"
  (setq tabulated-list-format
        [("" 1 t)
         ("Instance" 20 t)
         ("Directory" 30 t)
         ("Status" 10 t)
         ("Activity" 40 t)])
  (setq tabulated-list-padding 2)
  (setq tabulated-list-sort-key '("Directory" . nil))
  (add-hook 'tabulated-list-revert-hook
            #'claude-code-extras-manager--refresh nil t)
  (tabulated-list-init-header))

;;;; Entry Point

;;;###autoload
(defun claude-code-extras-manager ()
  "Open the Claude Code instance manager dashboard."
  (interactive)
  (let ((buf (get-buffer-create "*Claude Manager*")))
    (with-current-buffer buf
      (unless (derived-mode-p 'claude-code-extras-manager-mode)
        (claude-code-extras-manager-mode)
        (add-hook 'kill-buffer-hook
                  #'claude-code-extras-manager--stop-timer nil t))
      (setq claude-code-extras-manager--marked-buffers nil)
      (tabulated-list-revert))
    (claude-code-extras-manager--start-timer)
    (pop-to-buffer buf)))

(provide 'claude-code-manager)
;;; claude-code-manager.el ends here
