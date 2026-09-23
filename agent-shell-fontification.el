;;; agent-shell-fontification.el --- Semantic text faces -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Apply customizable faces to message prose and editable input.

;;; Code:

(require 'comint)
(require 'seq)
(require 'agent-shell-faces)

(declare-function agent-shell--live-input-prompt-p "agent-shell-prompt")

(defvar-local agent-shell-fontification--draft nil
  "Overlay styling the editable user message.")

(defun agent-shell-fontification--clear-message-face ()
  "Remove the reply face before Markdown measures and renders content.
For example, a table's source must not retain the prose font when its
cells are measured or when the table is redrawn after a window resize."
  (with-silent-modifications
    (dolist (property '(face font-lock-face))
      (let ((pos (point-min)))
        (while (< pos (point-max))
          (let ((end (next-single-property-change pos property nil (point-max)))
                (face (get-text-property pos property)))
            (cond
             ((eq face 'agent-shell-message)
              (remove-text-properties pos end (list property nil)))
             ((and (listp face) (memq 'agent-shell-message face))
              (put-text-property pos end property
                                 (remq 'agent-shell-message (copy-sequence face)))))
            (setq pos end)))))))

(defun agent-shell-fontification--apply-message-face ()
  "Apply the reply face to rendered prose, excluding code and tables.
For example, in \"plain `code`\", only \"plain\" gets the reply face.
The face is unstyled by default and can be customized independently."
  (with-silent-modifications
    (let ((pos (point-min)))
      (while (< pos (point-max))
        (let* ((end (next-property-change pos nil (point-max)))
               (face (or (get-text-property pos 'face)
                         (get-text-property pos 'font-lock-face)))
               (faces (if (listp face) face (list face))))
          (when (and (get-text-property pos 'agent-shell-message-body)
                     (not (get-text-property pos 'agent-shell-markdown-table-source))
                     (not (get-text-property pos 'agent-shell-markdown-source-block-body))
                     (not (seq-intersection
                           faces '(agent-shell-markdown-inline-code
                                   agent-shell-markdown-source-block
                                   agent-shell-markdown-source-block-language))))
            (when face
              (put-text-property pos end 'face face))
            (add-face-text-property pos end 'agent-shell-message)
            (put-text-property pos end 'font-lock-face (get-text-property pos 'face)))
          (setq pos end))))))

(defun agent-shell--face-tool-content (text face)
  "Style tool TEXT with FACE, retaining its role through Markdown.
For example, command fences retain `agent-shell-tool-command' after
rendering, alongside the source block and syntax faces."
  (when text
    (propertize (agent-shell--face-unstyled-text text face)
                'agent-shell-tool-face face)))

(defun agent-shell-fontification--apply-tool-faces ()
  "Restore tool content faces after Markdown rendering."
  (with-silent-modifications
    (let ((pos (point-min)))
      (while (< pos (point-max))
        (let ((end (next-property-change pos nil (point-max)))
              (role (get-text-property pos 'agent-shell-tool-face))
              (face (or (get-text-property pos 'face)
                        (get-text-property pos 'font-lock-face))))
          (when role
            (when face
              (put-text-property pos end 'face face))
            (unless (or (eq face role)
                        (and (listp face) (memq role face)))
              (add-face-text-property pos end role))
            (put-text-property pos end 'font-lock-face
                               (get-text-property pos 'face)))
          (setq pos end))))))

(defun agent-shell-fontification--update-draft (&rest _)
  "Move the draft overlay to the current editable message.
For example, in \"Agent> hello\", only \"hello\" receives the input face."
  (save-restriction
    (widen)
    (let ((start (cond
                  ((derived-mode-p 'agent-shell-viewport-edit-mode)
                   (point-min))
                  ((and (derived-mode-p 'agent-shell-mode)
                        (agent-shell--live-input-prompt-p comint-last-prompt))
                   (marker-position (cdr comint-last-prompt))))))
      (if start
          (progn
            (unless (overlayp agent-shell-fontification--draft)
              (setq agent-shell-fontification--draft
                    (make-overlay start (point-max) nil t t))
              (overlay-put agent-shell-fontification--draft
                           'face 'agent-shell-input))
            (move-overlay agent-shell-fontification--draft start (point-max)))
        (when (overlayp agent-shell-fontification--draft)
          (delete-overlay agent-shell-fontification--draft)
          (setq agent-shell-fontification--draft nil))))))

(defun agent-shell-fontification--initialize ()
  "Style editable input in shells and composing viewports."
  (add-hook 'after-change-functions #'agent-shell-fontification--update-draft nil t)
  (add-hook 'post-command-hook #'agent-shell-fontification--update-draft nil t)
  (add-hook 'agent-shell-section-functions #'agent-shell-fontification--update-draft nil t)
  (add-hook 'change-major-mode-hook #'agent-shell-fontification--clear-draft nil t)
  (agent-shell-fontification--update-draft))

(defun agent-shell-fontification--clear-draft ()
  "Remove the editable input overlay when changing major modes."
  (when (overlayp agent-shell-fontification--draft)
    (delete-overlay agent-shell-fontification--draft)
    (setq agent-shell-fontification--draft nil)))

(add-hook 'agent-shell-mode-hook #'agent-shell-fontification--initialize)
(add-hook 'agent-shell-viewport-edit-mode-hook #'agent-shell-fontification--initialize)

(provide 'agent-shell-fontification)
;;; agent-shell-fontification.el ends here
