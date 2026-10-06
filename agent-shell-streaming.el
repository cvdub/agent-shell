;;; agent-shell-streaming.el --- Paragraph streaming for agent-shell. -*- lexical-binding: t; -*-

;; Copyright (C) 2024 Alvaro Ramirez

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
;;
;; Buffer live agent text until paragraphs and fenced blocks are complete.

;;; Code:

(require 'map)
(require 'subr-x)
(eval-when-compile (require 'cl-lib))

(declare-function agent-shell--update-fragment "agent-shell")

(defun agent-shell--paragraph-boundary (text &optional scan-state)
  "Return the last complete paragraph or fenced block boundary in TEXT.
The result is a string index, or nil when TEXT has no complete block.
For example, TEXT \"One\\n\\nTwo\" returns 5.  Blank lines inside
backtick or tilde fences do not end a paragraph.
When SCAN-STATE is an alist, resume at its :scan-position and :fence,
updating both after scanning complete lines."
  (save-match-data
    (let ((start (or (map-elt scan-state :scan-position) 0))
          (fence (map-elt scan-state :fence))
          boundary)
      (while (string-match "\n" text start)
        (let* ((end (match-end 0))
               (line (substring text start (match-beginning 0))))
          (cond
           (fence
            (when (string-match
                   (concat "\\` \\{0,3\\}"
                           (regexp-quote (substring fence 0 1))
                           "\\{" (number-to-string (length fence)) ",\\}[ \t\r]*\\'")
                   line)
              (setq fence nil
                    boundary end)))
           ((string-match "\\` \\{0,3\\}\\(`\\{3,\\}\\|~\\{3,\\}\\)" line)
            (setq fence (match-string 1 line)))
           ((string-match-p "\\`[ \t\r]*\\'" line)
            (setq boundary end)))
          (setq start end)))
      (when scan-state
        (map-put! scan-state :scan-position start)
        (map-put! scan-state :fence fence))
      boundary)))

(defun agent-shell--display-agent-text (state pending text)
  "Display TEXT in STATE using fragment metadata from PENDING.
After the first display, PENDING's :create-new becomes nil so subsequent
paragraphs append to the same fragment."
  (agent-shell--update-fragment
   :state state
   :namespace-id (map-elt pending :namespace-id)
   :block-id (map-elt pending :block-id)
   :body (propertize text 'agent-shell-message-body t)
   :create-new (map-elt pending :create-new)
   :append t
   :navigation 'never
   :render-body-images t
   :above-last-prompt (map-elt pending :above-last-prompt))
  (map-put! pending :create-new nil))

(defun agent-shell--flush-agent-text (state)
  "Display any unfinished paragraph buffered in STATE.
For example, a pending \"Last sentence\" displays even without a newline."
  (when-let* ((pending (map-elt state :pending-agent-text)))
    (agent-shell--display-agent-text state pending (map-elt pending :body))
    (map-put! state :pending-agent-text nil)))

(cl-defun agent-shell--stream-agent-text
    (&key state namespace-id block-id body create-new buffered above-last-prompt)
  "Append BODY to STATE's agent message identified by BLOCK-ID.
NAMESPACE-ID, CREATE-NEW and ABOVE-LAST-PROMPT are fragment metadata.
When BUFFERED is non-nil, display only complete paragraphs or fenced
blocks and retain the remainder in STATE.  Otherwise display immediately.
For example, buffered BODY \"One\\n\\nTwo\" displays \"One\\n\\n\" and
retains \"Two\" until a later chunk or `agent-shell--flush-agent-text'."
  (unless buffered
    (agent-shell--flush-agent-text state))
  (let ((pending (or (map-elt state :pending-agent-text)
                     (list (cons :namespace-id namespace-id)
                           (cons :block-id block-id)
                           (cons :create-new create-new)
                           (cons :above-last-prompt above-last-prompt)
                           (cons :scan-position 0)
                           (cons :fence nil)
                           (cons :body "")))))
    (if (not buffered)
        (agent-shell--display-agent-text state pending body)
      (map-put! pending :body (concat (map-elt pending :body) body))
      (when-let* ((boundary (agent-shell--paragraph-boundary (map-elt pending :body) pending)))
        (agent-shell--display-agent-text
         state pending (substring (map-elt pending :body) 0 boundary))
        (map-put! pending :body (substring (map-elt pending :body) boundary))
        (map-put! pending :scan-position (- (map-elt pending :scan-position) boundary)))
      (map-put! state :pending-agent-text
                (unless (string-empty-p (map-elt pending :body)) pending)))))

(provide 'agent-shell-streaming)
;;; agent-shell-streaming.el ends here
