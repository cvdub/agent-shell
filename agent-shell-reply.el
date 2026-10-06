;;; agent-shell-reply.el --- Dedicated split reply editor  -*- lexical-binding: t -*-

;; Copyright (C) 2025 Alvaro Ramirez

;; Author: Alvaro Ramirez https://xenodium.com
;; URL: https://github.com/xenodium/agent-shell

;; This package is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.

;; This package is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Compose in a dedicated buffer while the normal viewport remains visible.

;;; Code:

(require 'map)
(require 'subr-x)
(require 'window)

(defvar agent-shell-viewport--clean-up)
(defvar agent-shell-viewport--compose-snapshot)

(declare-function agent-shell-viewport--shell-buffer "agent-shell-viewport")
(declare-function agent-shell-viewport--position "agent-shell-viewport")
(declare-function agent-shell-viewport-view-mode "agent-shell-viewport")
(declare-function agent-shell-viewport-edit-mode "agent-shell-viewport")
(declare-function agent-shell-viewport--prompt-start "agent-shell-viewport")
(declare-function agent-shell--project-name "agent-shell-project")

(defvar-local agent-shell-reply--layout nil
  "Alist containing :viewport, :upper, and :lower for a split reply.")
(put 'agent-shell-reply--layout 'permanent-local t)

(defvar-local agent-shell-reply--shell nil
  "Shell explicitly associated with a dedicated reply buffer.")
(put 'agent-shell-reply--shell 'permanent-local t)

(define-minor-mode agent-shell-reply-mode
  "Identify the dedicated split reply editor."
  :lighter " Reply"
  (when agent-shell-reply-mode (agent-shell-reply--header)))
(put 'agent-shell-reply-mode 'permanent-local t)

(defun agent-shell-reply--header-text ()
  "Format the reply's turn position, project, and thread name."
  (when-let* ((shell (agent-shell-viewport--shell-buffer)))
    (let ((position (agent-shell-viewport--position))
          (separator (propertize " ➤ " 'face 'default)))
      (concat
       " "
       (propertize (format "%d/%d" (or (map-elt position :current) 1)
                           (or (map-elt position :total) 1))
                   'face 'default 'help-echo "Turn / total turns")
       separator
       (with-current-buffer shell
         (concat
          (propertize (replace-regexp-in-string "%" "%%" (agent-shell--project-name))
                      'face 'agent-shell-session-directory 'help-echo "Project")
          separator
          (propertize (replace-regexp-in-string "%" "%%" (buffer-name))
                      'face 'agent-shell-session-title 'help-echo "Thread")))))))

(defun agent-shell-reply--header ()
  "Use a compact session header while composing a split reply."
  (when (and agent-shell-reply-mode
             (derived-mode-p 'agent-shell-viewport-edit-mode))
    (setq-local header-line-format
                '(:eval (agent-shell-reply--header-text)))))

(defun agent-shell-reply--close ()
  "Close the dedicated reply, returning to the normal viewport."
  (when-let* ((layout agent-shell-reply--layout))
    (setq agent-shell-reply--layout nil)
    (let ((viewport (map-elt layout :viewport))
          (upper (map-elt layout :upper))
          (lower (map-elt layout :lower)))
      (when (buffer-live-p viewport)
        (cond
         ((and (window-live-p upper) (eq (window-buffer upper) viewport))
          (when (and (window-live-p lower)
                     (eq (window-buffer lower) (current-buffer)))
            (delete-window lower))
          (select-window upper))
         ((and (window-live-p lower)
               (eq (window-buffer lower) (current-buffer)))
          (set-window-buffer lower viewport)
          (select-window lower)))))))

(defun agent-shell-reply--below (original &rest args)
  "Run ORIGINAL with ARGS in a dedicated editor below the viewport."
  (if (or agent-shell-reply-mode
          (not (derived-mode-p 'agent-shell-viewport-view-mode)))
      (apply original args)
    (let* ((viewport (current-buffer))
           (shell (agent-shell-viewport--shell-buffer))
           (upper (selected-window))
           (position (point))
           (region-mark (when (use-region-p) (mark)))
           (snapshot agent-shell-viewport--compose-snapshot)
           (reply (generate-new-buffer
                   (format "*Reply: %s*" (buffer-name shell))))
           (lower nil)
           (ready nil))
      (unwind-protect
          (progn
            ;; Split before touching the draft so a small frame fails cleanly.
            (let* ((height (window-total-height upper))
                   (reply-height (max window-min-height (/ height 3))))
              (when (< (- height reply-height) (window-min-size upper))
                (user-error "Window is too small for a split reply"))
              (setq lower (split-window upper (- reply-height) 'below)))
            (select-window lower)
            (switch-to-buffer reply)
            (setq agent-shell-reply--shell shell
                  agent-shell-reply--layout `((:viewport . ,viewport) (:upper . ,upper) (:lower . ,lower)))
            ;; Seed the editor with the viewed page so upstream reply and
            ;; quote commands retain their normal region/draft behavior.
            (agent-shell-viewport-view-mode)
            (let ((inhibit-read-only t)) (insert-buffer-substring viewport))
            (setq agent-shell-viewport--compose-snapshot snapshot)
            (goto-char position)
            (when region-mark (set-mark region-mark) (setq mark-active t))
            (apply original args)
            (agent-shell-reply-mode 1)
            (add-hook 'kill-buffer-hook #'agent-shell-reply--close nil t)
            (with-current-buffer viewport
              (setq agent-shell-viewport--compose-snapshot nil)
              (deactivate-mark))
            (setq ready t))
        (unless ready
          (when (window-live-p lower) (delete-window lower))
          (let ((agent-shell-viewport--clean-up nil))
            (when (buffer-live-p reply) (kill-buffer reply))))))))

(put 'agent-shell-reply--close 'permanent-local-hook t)

(defun agent-shell-reply--finish (original &rest args)
  "Run ORIGINAL with ARGS and close a completed reply split.
Keep the split if sending fails, cancellation is declined, or a prefix
argument requests continued composition."
  (let ((viewport (current-buffer))
        (draft (when (and agent-shell-reply--layout
                          (derived-mode-p 'agent-shell-viewport-edit-mode))
                 (buffer-string)))
        (position (point)))
    (condition-case err
        (prog1 (apply original args)
          (when (buffer-live-p viewport)
            (with-current-buffer viewport
              (when (and agent-shell-reply-mode
                         (derived-mode-p 'agent-shell-viewport-view-mode))
                (agent-shell-reply--close)
                (when (eq original #'agent-shell-viewport--compose-send)
                  (with-current-buffer (window-buffer (selected-window))
                    (when-let* ((start (agent-shell-viewport--prompt-start)))
                      (goto-char start)
                      (end-of-line))))
                (let ((agent-shell-viewport--clean-up nil))
                  (kill-buffer viewport))))))
      (error
       ;; Sending switches to view mode before calling the transport.
       ;; Restore the editor if that call fails synchronously.
       (when (and draft (buffer-live-p viewport))
         (with-current-buffer viewport
           (unless (derived-mode-p 'agent-shell-viewport-edit-mode)
             (agent-shell-viewport-edit-mode))
           (let ((inhibit-read-only t))
             (erase-buffer)
             (insert draft))
           (goto-char (min position (point-max)))))
       (signal (car err) (cdr err))))))

(provide 'agent-shell-reply)
;;; agent-shell-reply.el ends here
