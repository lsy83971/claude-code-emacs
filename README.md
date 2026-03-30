# claude-code-extras

Enhanced Emacs UI for [claude-code.el](https://github.com/stevemolitor/claude-code.el) — same-window display, copy/paste support, dedicated input buffer, and a multi-instance manager dashboard.

## Features

### claude-code-extras.el

- **Same-window display** — Claude buffers always open in the current window, no extra splits
- **Copy/Paste in vterm** — `M-w` to enter copy-mode / copy region, `C-y` to paste from kill-ring
- **Dedicated input buffer** — Multi-line editing with history, auto-opens below the Claude window
- **Spinner character fix** — Replaces Unicode spinner glyphs with `*` to avoid font line-height issues

### claude-code-extras-manager.el

- **Instance dashboard** — `tabulated-list-mode` based panel showing all Claude instances
- **Activity preview** — Shows the last line of terminal output for each instance
- **Batch operations** — Mark (`d`) / unmark (`u`) / execute (`x`) for bulk deletion
- **Auto-refresh** — Dashboard updates every 2 seconds (configurable)

## Dependencies

- Emacs **29.1+**
- [vterm](https://github.com/akermu/emacs-libvterm) — terminal backend
- [claude-code.el](https://github.com/stevemolitor/claude-code.el) — base Claude Code integration

## Installation

### From MELPA (recommended)

```elisp
(use-package claude-code-extras
  :ensure t
  :after claude-code
  :config
  (claude-code-extras-mode 1)
  ;; Optional: customize settings before enabling the mode
  ;; (setq claude-code-terminal-backend 'vterm)
  ;; Bind the manager dashboard
  (define-key claude-code-command-map (kbd "L") #'claude-code-extras-manager))
```

### Manual

Clone this repo and add to your `load-path`:

```elisp
(add-to-list 'load-path "/path/to/claude-code-emacs")
(require 'claude-code-extras)
(claude-code-extras-mode 1)

;; Bind the manager to C-c c L
(with-eval-after-load 'claude-code
  (define-key claude-code-command-map (kbd "L") #'claude-code-extras-manager))
```

## Keybindings

### Claude Buffer (vterm)

| Key | Action |
|-----|--------|
| `M-w` | Enter copy-mode / copy region and exit |
| `C-y` | Paste from kill-ring |
| `C-c c i` | Open dedicated input buffer |

### Input Buffer

| Key | Action |
|-----|--------|
| `C-RET` | Send to Claude |
| `C-up` | Previous history entry |
| `C-down` | Next history entry |
| `RET` | Insert newline |
| `C-r` | Send return to Claude (confirm/continue) |

### Manager Dashboard (`C-c c L`)

| Key | Action |
|-----|--------|
| `RET` / `o` | Switch to instance |
| `c` | Create new instance |
| `C` | Continue (--continue) |
| `k` | Kill instance at point |
| `K` | Kill all instances |
| `s` | Send command to instance |
| `d` | Mark for deletion |
| `u` | Unmark |
| `x` | Execute marked deletions |
| `q` | Quit dashboard |

## License

GPL-3.0-or-later
