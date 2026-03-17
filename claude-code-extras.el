;;; claude-code-extras.el --- Enhanced UI for claude-code.el -*- lexical-binding: t; -*-

;; Author: lishiyu
;; URL: https://github.com/lishiyu/claude-code-emacs
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (vterm "0.0.2") (claude-code "0.1"))
;; Keywords: tools, ai

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

;;; Code:

(require 'claude-code)

(use-package inheritenv :ensure t)
(use-package vterm :ensure t)

;;;; ============================================================
;;;; Same-Window Display
;;;; ============================================================

(setq claude-code-terminal-backend 'vterm)

;; Auto-revert buffers when files change on disk
(global-auto-revert-mode 1)
(setq auto-revert-use-notify nil)

;; Display Claude buffers in the current window (no extra splits)
(setq claude-code-display-window-fn
      (lambda (buffer)
        (display-buffer buffer '(display-buffer-same-window))))

;; Remove side-window parameters on startup
(add-hook 'claude-code-start-hook
          (lambda ()
            (when (derived-mode-p 'vterm-mode)
              (set-window-parameter nil 'window-side nil)
              (set-window-parameter nil 'window-slot nil))))

;; Flag: whether a Claude buffer is currently initializing
(defvar claude-code--initializing nil
  "Non-nil while a Claude buffer is being initialized.")

;; Intercept pop-to-buffer for Claude buffers: always use switch-to-buffer
;; Also set the initializing flag to prevent vterm's internal delete-window
(define-advice pop-to-buffer (:around (orig-fn buffer &rest args) claude-code-same-window)
  "Display all Claude buffers in the current window, no extra splits."
  (let* ((buf-name (if (bufferp buffer)
                       (buffer-name buffer)
                     (if (stringp buffer) buffer nil)))
         (is-claude (and buf-name (string-match-p "^\\*claude:" buf-name))))
    (if is-claude
        (progn
          ;; Set initializing flag; clear after 0.5s
          (setq claude-code--initializing t)
          (run-with-timer 0.5 nil (lambda () (setq claude-code--initializing nil)))
          (switch-to-buffer buffer))
      (apply orig-fn buffer args))))

;; Prevent delete-window from closing Claude windows during initialization
(define-advice delete-window (:around (orig-fn &optional window) claude-code-preserve-window)
  "Block window deletion for Claude buffers during initialization."
  (let* ((win (or window (selected-window)))
         (buf (window-buffer win))
         (buf-name (buffer-name buf)))
    (if (and claude-code--initializing
             buf-name
             (string-match-p "^\\*claude:" buf-name))
        nil  ; block deletion
      (funcall orig-fn window))))

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
;;                -> user's custom bindings in minor-mode-map-alist may take
;;                   priority over local keymap (step 4 > step 5)
;;                -> use minor-mode-overriding-map-alist (step 3) to override

(defun claude-code-smart-copy ()
  "M-w: enter copy-mode if not active; copy region and exit if active."
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
        ;; vterm--exit-copy-mode calls vterm-reset-cursor-point which jumps
        ;; point to end; restore both point and window-start to prevent
        ;; redisplay from scrolling to follow point
        (goto-char (min saved-point (point-max)))
        (set-window-start nil (min win-start (point-max)) t))
    ;; Save current viewport position, restore after entering copy-mode
    (let ((win-start (window-start))
          (win-point (window-point)))
      (claude-code--term-read-only-mode claude-code-terminal-backend)
      (set-window-start nil win-start t)
      (goto-char (max win-point win-start)))
    (message "Copy mode: C-SPC to set mark, move to select, M-w to copy and exit")))

(defun claude-code-paste ()
  "C-y: paste kill-ring top into the Claude vterm input area."
  (interactive)
  (when (bound-and-true-p vterm-copy-mode)
    (vterm-copy-mode -1)
    (setq-local cursor-type nil))
  (if kill-ring
      (vterm-send-string (substring-no-properties (current-kill 0)) t)
    (message "Kill ring is empty")))

;; Layer 1: Normal mode interception
;; vterm--self-insert-meta handles meta keys (M-w),
;; vterm--self-insert handles control keys (C-y)
(defun claude-code--intercept-vterm-meta (&rest _)
  "Intercept M-w in Claude buffers during normal mode."
  (when (claude-code--buffer-p (current-buffer))
    (cond
     ((eq last-command-event ?\M-w)
      (call-interactively #'claude-code-smart-copy) t)
     ((eq last-command-event ?\C-y)
      (call-interactively #'claude-code-paste) t))))

(defun claude-code--intercept-vterm-insert (&rest _)
  "Intercept C-y in Claude buffers during normal mode."
  (when (and (claude-code--buffer-p (current-buffer))
             (eq last-command-event ?\C-y))
    (call-interactively #'claude-code-paste) t))

(advice-add 'vterm--self-insert-meta :before-until #'claude-code--intercept-vterm-meta)
(advice-add 'vterm--self-insert      :before-until #'claude-code--intercept-vterm-insert)

;; Layer 2: Copy-mode interception
;; minor-mode-overriding-map-alist (step 3) > minor-mode-map-alist (step 4)
(defvar-local claude-code--copy-paste-active nil
  "Non-nil in Claude buffers to activate the copy/paste overriding keymap.")

(defun claude-code--setup-copy-paste-keys ()
  "Set up M-w / C-y overrides for copy-mode, overriding minor-mode-map-alist."
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "M-w") #'claude-code-smart-copy)
    (define-key map (kbd "C-y") #'claude-code-paste)
    (setq-local claude-code--copy-paste-active t)
    (setq-local minor-mode-overriding-map-alist
                (cons (cons 'claude-code--copy-paste-active map)
                      minor-mode-overriding-map-alist))))

(add-hook 'claude-code-start-hook #'claude-code--setup-copy-paste-keys)


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
;; The input buffer is a normal Emacs buffer with full editing/completion support.
;; Auto-opens below the Claude window on startup.

(defcustom claude-code-input-window-height 6
  "Height (in lines) of the input buffer window."
  :type 'integer
  :group 'claude-code)

(defvar-local claude-code-input--history '()
  "Send history, newest first (deduplicated).")

(defvar-local claude-code-input--history-index -1
  "History navigation position.  -1 means editing new input.")

(defvar-local claude-code-input--saved-input ""
  "Saved in-progress input before entering history navigation.")

(defvar-local claude-code-input--target nil
  "Name of the Claude buffer this input buffer is associated with.")

(defun claude-code-input-send ()
  "Send all input buffer content to Claude and clear the buffer."
  (interactive)
  (let ((content (string-trim
                  (buffer-substring-no-properties (point-min) (point-max)))))
    (when (string-empty-p content)
      (user-error "Input buffer is empty"))
    ;; Add to history (deduplicate, push to front)
    (setq claude-code-input--history
          (cons content (delete content claude-code-input--history))
          claude-code-input--history-index -1
          claude-code-input--saved-input "")
    ;; Send to the associated Claude vterm
    (let ((claude-buf (and claude-code-input--target
                           (get-buffer claude-code-input--target))))
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

(defun claude-code-input-history-prev ()
  "Recall the previous (older) history entry."
  (interactive)
  (unless claude-code-input--history
    (user-error "No send history"))
  ;; Save current edit on first history navigation
  (when (= claude-code-input--history-index -1)
    (setq claude-code-input--saved-input
          (buffer-substring-no-properties (point-min) (point-max))))
  (if (< (1+ claude-code-input--history-index)
         (length claude-code-input--history))
      (progn
        (setq claude-code-input--history-index
              (1+ claude-code-input--history-index))
        (erase-buffer)
        (insert (nth claude-code-input--history-index claude-code-input--history))
        (goto-char (point-max)))
    (message "Already at oldest entry")))

(defun claude-code-input-history-next ()
  "Recall the next (newer) history entry; restore edit at bottom."
  (interactive)
  (cond
   ((> claude-code-input--history-index 0)
    (setq claude-code-input--history-index
          (1- claude-code-input--history-index))
    (erase-buffer)
    (insert (nth claude-code-input--history-index claude-code-input--history))
    (goto-char (point-max)))
   ((= claude-code-input--history-index 0)
    (setq claude-code-input--history-index -1)
    (erase-buffer)
    (insert claude-code-input--saved-input)
    (goto-char (point-max)))
   (t
    (message "Already at newest"))))

(defvar claude-code-input-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-<return>") #'claude-code-input-send)
    (define-key map (kbd "C-r")
      (lambda () (interactive)
        (when-let ((claude-buf (and claude-code-input--target
                                    (get-buffer claude-code-input--target))))
          (with-current-buffer claude-buf (vterm-send-return)))))
    (define-key map (kbd "C-<up>")     #'claude-code-input-history-prev)
    (define-key map (kbd "C-<down>")   #'claude-code-input-history-next)
    map)
  "Keymap for `claude-code-input-mode'.")

(define-minor-mode claude-code-input-mode
  "Claude Code dedicated input mode.
C-RET to send, C-up/C-down to browse history, RET for newline."
  :lighter " CI"
  :keymap claude-code-input-mode-map
  (if claude-code-input-mode
      (setq-local header-line-format
                  (list " Claude Input -> "
                        '(:eval (or claude-code-input--target "?"))
                        "    C-RET send  C-up prev  C-down next"))
    (setq-local header-line-format nil)))

(defun claude-code-open-input ()
  "Open the dedicated input buffer for the current Claude instance.
If the window already exists, just switch to it."
  (interactive)
  (let* ((claude-buf  (claude-code--get-or-prompt-for-buffer))
         (input-name  (format "*claude-input%s*"
                              (if claude-buf
                                  (concat ":" (buffer-name claude-buf))
                                "")))
         (input-buf   (get-buffer-create input-name))
         (is-new      (not (buffer-local-value 'claude-code-input-mode input-buf))))
    (with-current-buffer input-buf
      (when is-new
        (claude-code-input-mode 1))
      ;; Update target (Claude buffer may have restarted)
      (setq-local claude-code-input--target
                  (and claude-buf (buffer-name claude-buf))))
    (if-let ((win (get-buffer-window input-buf)))
        (select-window win)
      (let* ((claude-win (and claude-buf (get-buffer-window claude-buf t)))
             (win (if claude-win
                      (with-selected-window claude-win
                        (display-buffer input-buf
                                        `((display-buffer-reuse-window display-buffer-below-selected)
                                          (window-height . ,claude-code-input-window-height))))
                    (display-buffer input-buf
                                    `((display-buffer-pop-up-window)
                                      (window-height . ,claude-code-input-window-height))))))
        (when win (select-window win))))))

(defun claude-code--auto-open-input ()
  "Auto-open the input buffer below the Claude window on startup."
  (let ((claude-buf (current-buffer)))
    (run-with-timer
     0.3 nil
     (lambda ()
       (when (buffer-live-p claude-buf)
         (let* ((input-name (format "*claude-input:%s*" (buffer-name claude-buf)))
                (input-buf  (get-buffer-create input-name)))
           (with-current-buffer input-buf
             (unless claude-code-input-mode
               (claude-code-input-mode 1))
             (setq-local claude-code-input--target (buffer-name claude-buf)))

           (unless (get-buffer-window input-buf t)
             (let ((claude-win (get-buffer-window claude-buf t)))
               (if claude-win
                   (with-selected-window claude-win
                     (display-buffer input-buf
                                     `(display-buffer-below-selected
                                       (window-height . ,claude-code-input-window-height)
                                       (preserve-size . (nil . t)))))
                 (display-buffer input-buf
                                 `(display-buffer-pop-up-window
                                   (window-height . ,claude-code-input-window-height))))))))))))
(add-hook 'claude-code-start-hook #'claude-code--auto-open-input)

(defun claude-code--auto-kill-input ()
  "Auto-kill the input buffer when the associated Claude buffer is killed."
  (let ((input-buf (get-buffer (format "*claude-input:%s*" (buffer-name)))))
    (when (buffer-live-p input-buf)
      (let ((win (get-buffer-window input-buf t)))
        (when win (delete-window win)))
      (kill-buffer input-buf))))

(add-hook 'claude-code-start-hook
          (lambda ()
            (add-hook 'kill-buffer-hook #'claude-code--auto-kill-input nil t)))

(with-eval-after-load 'claude-code
  (define-key claude-code-command-map (kbd "i") #'claude-code-open-input))

;;;; ============================================================
;;;; Spinner Character Fix
;;;; ============================================================
;; Some spinner characters (U+2722, U+273B, U+273D) are not in certain fonts
;; (e.g. Sarasa Fixed SC), causing fallback to fonts with different line heights.
;; Replace them with plain asterisks via display-table and buffer content.

(defun claude-code--fix-spinner-char ()
  "Replace special spinner characters with plain asterisks in Claude buffers."
  (let ((buf (current-buffer)))
    (run-with-timer
     0.5 nil
     `(lambda ()
        (when (buffer-live-p ,buf)
          (with-current-buffer ,buf
            (let ((table (or buffer-display-table (make-display-table))))
              (aset table ?\u2722 (vector ?*))  ; four teardrop-spoked asterisk
              (aset table ?\u273B (vector ?*))  ; teardrop-spoked asterisk
              (aset table ?\u273D (vector ?*))  ; heavy teardrop-spoked asterisk
              (setq buffer-display-table table)
              ;; Also replace in buffer content directly
              (save-excursion
                (goto-char (point-min))
                (while (re-search-forward "[\u2722\u273B\u273D]" nil t)
                  (replace-match "*" nil nil))))))))))
(add-hook 'claude-code-start-hook #'claude-code--fix-spinner-char)

(provide 'claude-code-extras)
;;; claude-code-extras.el ends here
