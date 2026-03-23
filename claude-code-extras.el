;;; claude-code-extras.el --- Enhanced UI for claude-code.el -*- lexical-binding: t; -*-

;; Author: lishiyu <522583971@qq.com>
;; URL: https://github.com/lsy83971/claude-code-emacs
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (vterm "0.0.2") (claude-code "0.1"))
;; Keywords: tools, ai
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

;; Enhancements for claude-code.el (https://github.com/stevemolitor/claude-code.el):
;;
;; 1. Same-window display: Claude buffers always open in the current window,
;;    preventing extra window splits during startup.
;;
;; 2. Copy/Paste in vterm: M-w enters copy-mode (or copies region and exits),
;;    C-y pastes from kill-ring into the Claude terminal input.
;;    Two-layer interception handles both normal mode (via advice on
;;    vterm--self-insert*) and copy-mode (via minor-mode-overriding-map-alist).
;;
;; 3. Dedicated input buffer: A separate Emacs buffer for composing multi-line
;;    input with full editing support.  C-RET sends, C-up/C-down navigates
;;    history, RET inserts newline.  Auto-opens below the Claude window.
;;
;; 4. Spinner character fix: Replaces special Unicode spinner characters
;;    (U+2722, U+273B, U+273D) with plain asterisks to avoid font fallback
;;    line-height issues.
;;
;; To enable, add to your init file:
;;
;;   (require \\='claude-code-extras)
;;   (claude-code-extras-mode 1)
;;
;; You may also want to customize:
;;
;;   (setq claude-code-terminal-backend \\='vterm)
;;   (setq claude-code-display-window-fn
;;         (lambda (buffer)
;;           (display-buffer buffer \\='(display-buffer-same-window))))

;;; Code:

(require 'claude-code)

(declare-function vterm-send-string "vterm")
(declare-function vterm-send-return "vterm")
(declare-function vterm-copy-mode "vterm")
(declare-function vterm--filter-buffer-substring "vterm")
(declare-function claude-code--buffer-p "claude-code")
(declare-function claude-code--term-read-only-mode "claude-code")
(declare-function claude-code--get-or-prompt-for-buffer "claude-code")

(defvar claude-code-terminal-backend)
(defvar claude-code-command-map)
(defvar vterm-copy-mode)

;;;; ============================================================
;;;; Customization
;;;; ============================================================

(defgroup claude-code-extras nil
  "Enhanced UI for claude-code.el."
  :group 'claude-code
  :prefix "claude-code-extras-")

(defcustom claude-code-extras-input-window-height 6
  "Height (in lines) of the input buffer window."
  :type 'integer
  :group 'claude-code-extras)

;;;; ============================================================
;;;; Same-Window Display
;;;; ============================================================

(defvar claude-code-extras--initializing nil
  "Non-nil while a Claude buffer is being initialized.")

(defun claude-code-extras--pop-to-buffer-advice (orig-fn buffer &rest args)
  "Display Claude buffers in the current window, no extra splits.
Advice for `pop-to-buffer'.  ORIG-FN is the original function,
BUFFER and ARGS are its arguments."
  (let* ((buf-name (cond ((bufferp buffer) (buffer-name buffer))
                         ((stringp buffer) buffer)))
         (is-claude (and buf-name (string-match-p "^\\*claude:" buf-name))))
    (if is-claude
        (progn
          (setq claude-code-extras--initializing t)
          (run-with-timer 0.5 nil (lambda () (setq claude-code-extras--initializing nil)))
          (switch-to-buffer buffer))
      (apply orig-fn buffer args))))

(defun claude-code-extras--delete-window-advice (orig-fn &optional window)
  "Block window deletion for Claude buffers during initialization.
Advice for `delete-window'.  ORIG-FN is the original function,
WINDOW is the window to delete."
  (let* ((win (or window (selected-window)))
         (buf (window-buffer win))
         (buf-name (buffer-name buf)))
    (if (and claude-code-extras--initializing
             buf-name
             (string-match-p "^\\*claude:" buf-name))
        nil
      (funcall orig-fn window))))

(defun claude-code-extras--remove-side-window-params ()
  "Remove side-window parameters on Claude startup."
  (when (derived-mode-p 'vterm-mode)
    (set-window-parameter nil 'window-side nil)
    (set-window-parameter nil 'window-slot nil)))

;;;; ============================================================
;;;; Copy/Paste Keybindings (vterm backend)
;;;; ============================================================
;;
;;   M-w  -> Normal mode: enter copy-mode (cursor stays at terminal position)
;;           Copy mode: copy selected region and exit
;;   C-y  -> Paste kill-ring top into Claude terminal input
;;
;; Keyboard interception has two layers:
;;   Normal mode: vterm uses vterm--self-insert / vterm--self-insert-meta
;;                to intercept all keys
;;                -> advice :before-until intercepts M-w / C-y in Claude buffers
;;   Copy mode:   vterm--self-insert* don't fire, normal keymap lookup applies
;;                -> use minor-mode-overriding-map-alist (step 3) to override

(defun claude-code-extras-smart-copy ()
  "Smart copy for Claude buffers.
Enter copy-mode if not active; copy region and exit if active."
  (interactive)
  (if (bound-and-true-p vterm-copy-mode)
      (let ((win-start (window-start))
            (saved-point (point)))
        (when (use-region-p)
          (let* ((raw (buffer-substring (region-beginning) (region-end)))
                 (cleaned (vterm--filter-buffer-substring raw)))
            (kill-new cleaned)
            (deactivate-mark))
          (message "Copied to kill-ring"))
        (vterm-copy-mode -1)
        (setq-local cursor-type nil)
        (goto-char (min saved-point (point-max)))
        (set-window-start nil (min win-start (point-max)) t))
    (let ((win-start (window-start))
          (win-point (window-point)))
      (claude-code--term-read-only-mode claude-code-terminal-backend)
      (set-window-start nil win-start t)
      (goto-char (max win-point win-start)))
    (message "Copy mode: C-SPC to set mark, move to select, M-w to copy and exit")))

(defun claude-code-extras-paste ()
  "Paste `kill-ring' top into the Claude vterm input area."
  (interactive)
  (when (bound-and-true-p vterm-copy-mode)
    (vterm-copy-mode -1)
    (setq-local cursor-type nil))
  (if kill-ring
      (vterm-send-string (substring-no-properties (current-kill 0)) t)
    (message "Kill ring is empty")))

;; Layer 1: Normal mode interception
(defun claude-code-extras--intercept-vterm-meta (&rest _)
  "Intercept copy/paste keys in Claude buffers during normal mode."
  (when (claude-code--buffer-p (current-buffer))
    (cond
     ((eq last-command-event ?\M-w)
      (call-interactively #'claude-code-extras-smart-copy) t)
     ((eq last-command-event ?\C-y)
      (call-interactively #'claude-code-extras-paste) t))))

(defun claude-code-extras--intercept-vterm-insert (&rest _)
  "Intercept paste key in Claude buffers during normal mode."
  (when (and (claude-code--buffer-p (current-buffer))
             (eq last-command-event ?\C-y))
    (call-interactively #'claude-code-extras-paste) t))

;; Layer 2: Copy-mode interception
(defvar-local claude-code-extras--copy-paste-active nil
  "Non-nil in Claude buffers to activate the copy/paste overriding keymap.")

(defun claude-code-extras--setup-copy-paste-keys ()
  "Set up copy/paste overrides for copy-mode.
Override bindings in `minor-mode-map-alist'."
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "M-w") #'claude-code-extras-smart-copy)
    (define-key map (kbd "C-y") #'claude-code-extras-paste)
    (setq-local claude-code-extras--copy-paste-active t)
    (setq-local minor-mode-overriding-map-alist
                (cons (cons 'claude-code-extras--copy-paste-active map)
                      minor-mode-overriding-map-alist))))

;;;; ============================================================
;;;; Dedicated Input Buffer
;;;; ============================================================
;;
;;   C-c c i  -> Open input buffer (displayed below Claude window, focus moves there)
;;   C-RET    -> Send all input buffer content to Claude and clear
;;   C-up     -> Recall previous send history entry
;;   C-down   -> Recall next entry (restores in-progress edit at bottom)
;;   RET      -> Insert newline (supports multi-line input)
;;
;; Each Claude buffer has its own input buffer with buffer-local history.

(defvar-local claude-code-extras-input--history '()
  "Send history, newest first (deduplicated).")

(defvar-local claude-code-extras-input--history-index -1
  "History navigation position.  -1 means editing new input.")

(defvar-local claude-code-extras-input--saved-input ""
  "Saved in-progress input before entering history navigation.")

(defvar-local claude-code-extras-input--target nil
  "Name of the Claude buffer this input buffer is associated with.")

(defun claude-code-extras-input-send ()
  "Send all input buffer content to Claude and clear the buffer."
  (interactive)
  (let ((content (string-trim
                  (buffer-substring-no-properties (point-min) (point-max)))))
    (when (string-empty-p content)
      (user-error "Input buffer is empty"))
    (setq claude-code-extras-input--history
          (cons content (delete content claude-code-extras-input--history))
          claude-code-extras-input--history-index -1
          claude-code-extras-input--saved-input "")
    (let ((claude-buf (and claude-code-extras-input--target
                           (get-buffer claude-code-extras-input--target))))
      (unless (buffer-live-p claude-buf)
        (setq claude-buf (claude-code--get-or-prompt-for-buffer)))
      (if (not (buffer-live-p claude-buf))
          (user-error "Cannot find Claude buffer; please start Claude first")
        (with-current-buffer claude-buf
          (when (bound-and-true-p vterm-copy-mode)
            (vterm-copy-mode -1)
            (setq-local cursor-type nil))
          (vterm-send-string content t)
          (vterm-send-return))))
    (erase-buffer)
    (message "Sent to Claude")))

(defun claude-code-extras-input-history-prev ()
  "Recall the previous (older) history entry."
  (interactive)
  (unless claude-code-extras-input--history
    (user-error "No send history"))
  (when (= claude-code-extras-input--history-index -1)
    (setq claude-code-extras-input--saved-input
          (buffer-substring-no-properties (point-min) (point-max))))
  (if (< (1+ claude-code-extras-input--history-index)
         (length claude-code-extras-input--history))
      (progn
        (setq claude-code-extras-input--history-index
              (1+ claude-code-extras-input--history-index))
        (erase-buffer)
        (insert (nth claude-code-extras-input--history-index
                     claude-code-extras-input--history))
        (goto-char (point-max)))
    (message "Already at oldest entry")))

(defun claude-code-extras-input-history-next ()
  "Recall the next (newer) history entry; restore edit at bottom."
  (interactive)
  (cond
   ((> claude-code-extras-input--history-index 0)
    (setq claude-code-extras-input--history-index
          (1- claude-code-extras-input--history-index))
    (erase-buffer)
    (insert (nth claude-code-extras-input--history-index
                 claude-code-extras-input--history))
    (goto-char (point-max)))
   ((= claude-code-extras-input--history-index 0)
    (setq claude-code-extras-input--history-index -1)
    (erase-buffer)
    (insert claude-code-extras-input--saved-input)
    (goto-char (point-max)))
   (t
    (message "Already at newest"))))

(defun claude-code-extras--input-send-return ()
  "Send return to the associated Claude buffer."
  (interactive)
  (when-let ((claude-buf (and claude-code-extras-input--target
                              (get-buffer claude-code-extras-input--target))))
    (with-current-buffer claude-buf (vterm-send-return))))

(defvar claude-code-extras-input-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-<return>") #'claude-code-extras-input-send)
    (define-key map (kbd "C-r") #'claude-code-extras--input-send-return)
    (define-key map (kbd "C-<up>") #'claude-code-extras-input-history-prev)
    (define-key map (kbd "C-<down>") #'claude-code-extras-input-history-next)
    map)
  "Keymap for `claude-code-extras-input-mode'.")

(define-minor-mode claude-code-extras-input-mode
  "Claude Code dedicated input mode.
C-RET to send, C-up/C-down to browse history, RET for newline."
  :lighter " CI"
  :keymap claude-code-extras-input-mode-map
  (if claude-code-extras-input-mode
      (setq-local header-line-format
                  (list " Claude Input -> "
                        '(:eval (or claude-code-extras-input--target "?"))
                        "    C-RET send  C-up prev  C-down next"))
    (setq-local header-line-format nil)))

;;;###autoload
(defun claude-code-extras-open-input ()
  "Open the dedicated input buffer for the current Claude instance.
If the window already exists, just switch to it."
  (interactive)
  (let* ((claude-buf (claude-code--get-or-prompt-for-buffer))
         (input-name (format "*claude-input%s*"
                             (if claude-buf
                                 (concat ":" (buffer-name claude-buf))
                               "")))
         (input-buf (get-buffer-create input-name))
         (is-new (not (buffer-local-value
                       'claude-code-extras-input-mode input-buf))))
    (with-current-buffer input-buf
      (when is-new
        (claude-code-extras-input-mode 1))
      (setq-local claude-code-extras-input--target
                  (and claude-buf (buffer-name claude-buf))))
    (if-let ((win (get-buffer-window input-buf)))
        (select-window win)
      (let* ((claude-win (and claude-buf (get-buffer-window claude-buf t)))
             (height claude-code-extras-input-window-height)
             (win (if claude-win
                      (with-selected-window claude-win
                        (display-buffer
                         input-buf
                         `((display-buffer-reuse-window
                            display-buffer-below-selected)
                           (window-height . ,height))))
                    (display-buffer
                     input-buf
                     `((display-buffer-pop-up-window)
                       (window-height . ,height))))))
        (when win (select-window win))))))

(defun claude-code-extras--auto-open-input ()
  "Auto-open the input buffer below the Claude window on startup."
  (let ((claude-buf (current-buffer)))
    (run-with-timer
     0.3 nil
     (lambda ()
       (when (buffer-live-p claude-buf)
         (let* ((input-name (format "*claude-input:%s*"
                                    (buffer-name claude-buf)))
                (input-buf (get-buffer-create input-name))
                (height claude-code-extras-input-window-height))
           (with-current-buffer input-buf
             (unless claude-code-extras-input-mode
               (claude-code-extras-input-mode 1))
             (setq-local claude-code-extras-input--target
                         (buffer-name claude-buf)))
           (unless (get-buffer-window input-buf t)
             (let ((claude-win (get-buffer-window claude-buf t)))
               (if claude-win
                   (with-selected-window claude-win
                     (display-buffer
                      input-buf
                      `(display-buffer-below-selected
                        (window-height . ,height)
                        (preserve-size . (nil . t)))))
                 (display-buffer
                  input-buf
                  `(display-buffer-pop-up-window
                    (window-height . ,height))))))))))))

(defun claude-code-extras--auto-kill-input ()
  "Auto-kill the input buffer when the associated Claude buffer is killed."
  (let ((input-buf (get-buffer (format "*claude-input:%s*" (buffer-name)))))
    (when (buffer-live-p input-buf)
      (let ((win (get-buffer-window input-buf t)))
        (when win (delete-window win)))
      (kill-buffer input-buf))))

(defun claude-code-extras--setup-kill-hook ()
  "Set up kill-buffer-hook in Claude buffers to auto-kill input buffer."
  (add-hook 'kill-buffer-hook #'claude-code-extras--auto-kill-input nil t))

;;;; ============================================================
;;;; Spinner Character Fix
;;;; ============================================================

(defun claude-code-extras--fix-spinner-char ()
  "Replace special spinner characters with plain asterisks in Claude buffers.
Some spinner characters (U+2722, U+273B, U+273D) are not in certain fonts,
causing fallback to fonts with different line heights."
  (let ((buf (current-buffer)))
    (run-with-timer
     0.5 nil
     (lambda ()
       (when (buffer-live-p buf)
         (with-current-buffer buf
           (let ((table (or buffer-display-table (make-display-table))))
             (aset table ?\u2722 (vector ?*))
             (aset table ?\u273B (vector ?*))
             (aset table ?\u273D (vector ?*))
             (setq buffer-display-table table)
             (save-excursion
               (goto-char (point-min))
               (while (re-search-forward "[\u2722\u273B\u273D]" nil t)
                 (replace-match "*" nil nil))))))))))

;;;; ============================================================
;;;; Global Minor Mode
;;;; ============================================================

(defvar claude-code-extras--saved-input-key nil
  "Previous binding of \"i\" in `claude-code-command-map', if any.")

;;;###autoload
(define-minor-mode claude-code-extras-mode
  "Global minor mode providing enhanced UI for claude-code.el.
When enabled, activates same-window display, copy/paste keybindings,
dedicated input buffer, and spinner character fix."
  :global t
  :group 'claude-code-extras
  (if claude-code-extras-mode
      (progn
        ;; Same-window display advice
        (advice-add 'pop-to-buffer :around
                    #'claude-code-extras--pop-to-buffer-advice)
        (advice-add 'delete-window :around
                    #'claude-code-extras--delete-window-advice)
        ;; Copy/paste advice
        (advice-add 'vterm--self-insert-meta :before-until
                    #'claude-code-extras--intercept-vterm-meta)
        (advice-add 'vterm--self-insert :before-until
                    #'claude-code-extras--intercept-vterm-insert)
        ;; Hooks
        (add-hook 'claude-code-start-hook
                  #'claude-code-extras--remove-side-window-params)
        (add-hook 'claude-code-start-hook
                  #'claude-code-extras--setup-copy-paste-keys)
        (add-hook 'claude-code-start-hook
                  #'claude-code-extras--auto-open-input)
        (add-hook 'claude-code-start-hook
                  #'claude-code-extras--setup-kill-hook)
        (add-hook 'claude-code-start-hook
                  #'claude-code-extras--fix-spinner-char)
        ;; Keybinding in claude-code-command-map
        (when (boundp 'claude-code-command-map)
          (setq claude-code-extras--saved-input-key
                (lookup-key claude-code-command-map (kbd "i")))
          (define-key claude-code-command-map (kbd "i")
                      #'claude-code-extras-open-input)))
    ;; Teardown
    (advice-remove 'pop-to-buffer
                   #'claude-code-extras--pop-to-buffer-advice)
    (advice-remove 'delete-window
                   #'claude-code-extras--delete-window-advice)
    (advice-remove 'vterm--self-insert-meta
                   #'claude-code-extras--intercept-vterm-meta)
    (advice-remove 'vterm--self-insert
                   #'claude-code-extras--intercept-vterm-insert)
    (remove-hook 'claude-code-start-hook
                 #'claude-code-extras--remove-side-window-params)
    (remove-hook 'claude-code-start-hook
                 #'claude-code-extras--setup-copy-paste-keys)
    (remove-hook 'claude-code-start-hook
                 #'claude-code-extras--auto-open-input)
    (remove-hook 'claude-code-start-hook
                 #'claude-code-extras--setup-kill-hook)
    (remove-hook 'claude-code-start-hook
                 #'claude-code-extras--fix-spinner-char)
    (when (boundp 'claude-code-command-map)
      (define-key claude-code-command-map (kbd "i")
                  claude-code-extras--saved-input-key))))

(provide 'claude-code-extras)
;;; claude-code-extras.el ends here
