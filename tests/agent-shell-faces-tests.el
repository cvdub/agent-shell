;;; agent-shell-faces-tests.el --- Text face tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'agent-shell)

(ert-deftest agent-shell-faces-draft-follows-prompt ()
  "Draft styling excludes labels and output inserted above a live prompt."
  (with-temp-buffer
    (comint-mode)
    (setq major-mode 'agent-shell-mode)
    (insert "Agent> ")
    (setq-local comint-last-prompt
                (cons (copy-marker 1) (copy-marker (point))))
    (agent-shell-fontification--initialize)
    (insert "hello")
    (should (= (overlay-start agent-shell-fontification--draft) 8))
    (should (= (overlay-end agent-shell-fontification--draft) (point-max)))
    (let ((input (buffer-substring-no-properties
                  (overlay-start agent-shell-fontification--draft) (point-max))))
      (agent-shell--with-buffer-narrowed-to (car comint-last-prompt)
        (goto-char (point-max))
        (insert (propertize "tool output\n" 'field 'output)))
      (agent-shell-fontification--update-draft)
      (should (equal input (buffer-substring-no-properties
                            (overlay-start agent-shell-fontification--draft)
                            (overlay-end agent-shell-fontification--draft)))))
    (goto-char (point-max))
    (insert (propertize "output" 'field 'output))
    (should-not agent-shell-fontification--draft)))

(ert-deftest agent-shell-faces-agent-message-dispatch ()
  "Agent replies, including streaming chunks, retain their semantic face."
  (let ((state (agent-shell--make-state))
        (chunks nil))
    (cl-letf (((symbol-function 'agent-shell--active-requests-p) (lambda (_) t))
              ((symbol-function 'agent-shell--append-transcript) #'ignore)
              ((symbol-function 'agent-shell--emit-event) #'ignore)
              ((symbol-function 'agent-shell--update-fragment)
               (lambda (&rest args) (push (plist-get args :body) chunks))))
      (dolist (text '("plain **bo" "ld** `code`"))
        (agent-shell--on-notification
         :state state
         :acp-notification `((method . "session/update")
                             (params
                              (update
                               (sessionUpdate . "agent_message_chunk")
                               (content (type . "text") (text . ,text)))))))
      (dolist (chunk chunks)
        (should (get-text-property 0 'agent-shell-message-body chunk)))
      (with-temp-buffer
        (agent-shell-fontification--initialize)
        (dolist (chunk (nreverse chunks))
          (goto-char (point-max))
          (insert chunk)
          (agent-shell--render-markdown))
        (should (equal "plain bold code" (buffer-string)))
        (should (equal '(agent-shell-message agent-shell-markdown-bold)
                       (get-text-property 7 'font-lock-face)))
        (should (eq 'agent-shell-markdown-inline-code
                       (get-text-property 12 'font-lock-face)))))))

(ert-deftest agent-shell-faces-restored-user-message ()
  "Restored messages use the input face without styling the prompt label."
  (let ((state (agent-shell--make-state
                :agent-config '((:shell-prompt . "Agent> "))))
        (text nil))
    (map-put! state :active-requests '(((:method . "session/load"))))
    (cl-letf (((symbol-function 'agent-shell--append-transcript) #'ignore)
              ((symbol-function 'agent-shell--update-text)
               (lambda (&rest args) (setq text (plist-get args :text)))))
      (agent-shell--on-notification
       :state state
       :acp-notification '((method . "session/update")
                           (params (update
                                    (sessionUpdate . "user_message_chunk")
                                    (content (type . "text") (text . "hello"))))))
      (should (memq 'agent-shell-prompt (get-text-property 0 'font-lock-face text)))
      (should (eq 'agent-shell-input (get-text-property 7 'font-lock-face text))))))

(ert-deftest agent-shell-faces-markdown-exceptions ()
  "Code and tables retain their own faces inside a reply."
  (with-temp-buffer
    (agent-shell-fontification--initialize)
    (insert (propertize "Prose\n\n```elisp\n(+ 1 2)\n```\n\n| A | B |\n|---|---|\n| x | y |\n\nAfter\n"
                        'agent-shell-message-body t))
    (agent-shell--render-markdown :complete t)
    (goto-char (point-min))
    (search-forward "(+ 1 2)")
    (should (get-text-property (match-beginning 0) 'agent-shell-markdown-source-block-body))
    (goto-char (point-min))
    (search-forward "x")
    (should (get-text-property (match-beginning 0) 'agent-shell-markdown-table-source))
    (should (eq 'agent-shell-markdown-table
                (get-text-property (match-beginning 0) 'font-lock-face)))
    (search-forward "After")
    (should (eq 'agent-shell-message (get-text-property (match-beginning 0) 'font-lock-face)))))

(ert-deftest agent-shell-faces-fontification-keeps-markdown ()
  "Fontification clearing `face' must not lose emphasis or code styling."
  (with-temp-buffer
    (insert (propertize "**bold** `code`\n\nNext paragraph\n"
                        'agent-shell-message-body t))
    (agent-shell--render-markdown :complete t)
    (remove-text-properties (point-min) (point-max) '(face nil))
    (agent-shell--render-markdown :complete t)
    (goto-char (point-min))
    (search-forward "bold")
    (should (equal '(agent-shell-message agent-shell-markdown-bold)
                   (get-text-property (1- (point)) 'font-lock-face)))
    (search-forward "code")
    (should (eq 'agent-shell-markdown-inline-code
                (get-text-property (1- (point)) 'font-lock-face)))))

(ert-deftest agent-shell-faces-unstyled-output ()
  "Plain runs gain a face without replacing colored runs or mutating input."
  (let* ((source (concat "plain " (propertize "warning" 'font-lock-face 'agent-shell-warning)))
         (text (agent-shell--face-unstyled-text source 'agent-shell-output)))
    (should-not (get-text-property 0 'face source))
    (should (eq 'agent-shell-output (get-text-property 0 'face text)))
    (should (eq 'agent-shell-output (get-text-property 0 'font-lock-face text)))
    (should (eq 'agent-shell-warning (get-text-property 6 'font-lock-face text)))))

(ert-deftest agent-shell-faces-fragment-rendering ()
  "Bodies and indicators retain faces across streaming and folding."
  (with-temp-buffer
    (comint-mode)
    (setq major-mode 'agent-shell-mode)
    (let ((agent-shell-persistent-prompt-enabled nil)
          (state (agent-shell--make-state :buffer (current-buffer))))
      (agent-shell--update-fragment
       :state state :block-id "tool" :label-left "Tool" :label-right "Title"
       :body "Plain **bold**" :expanded t)
      (agent-shell--update-fragment
       :state state :block-id "tool" :body " appended" :append t)
      (dolist (entry '(("▼" . agent-shell-fold-indicator)
                       ("Tool" . agent-shell-section-heading)
                       ("Title" . agent-shell-section-title)
                       ("Plain" . agent-shell-section-body)
                       ("appended" . agent-shell-section-body)))
        (goto-char (point-min))
        (search-forward (car entry))
        (should (eq (cdr entry) (get-text-property (1- (point)) 'font-lock-face))))
      (goto-char (point-min))
      (search-forward "bold")
      (should (memq 'agent-shell-markdown-bold
                    (get-text-property (1- (point)) 'font-lock-face)))
      (agent-shell--update-fragment
       :state state :block-id "collapsed" :label-left "Details"
       :body "Hidden body" :expanded nil)
      (goto-char (point-min))
      (search-forward "Hidden body")
      (should (get-char-property (1- (point)) 'invisible))
      (should (eq 'agent-shell-section-body
                  (get-text-property (1- (point)) 'font-lock-face)))
      (agent-shell-ui-toggle-fragment)
      (goto-char (point-min))
      (search-forward "Hidden body")
      (should (eq 'agent-shell-section-body
                  (get-text-property (1- (point)) 'font-lock-face))))))

(ert-deftest agent-shell-faces-viewport-draft ()
  "Composing viewports use the input face and clear it when viewing."
  (with-temp-buffer
    (cl-letf (((symbol-function 'agent-shell-viewport--update-header) #'ignore))
      (let ((agent-shell-file-completion-enabled nil))
        (agent-shell-viewport-edit-mode))
      (insert "draft")
      (should (eq 'agent-shell-input
                  (overlay-get agent-shell-fontification--draft 'face)))
      (should (= (overlay-start agent-shell-fontification--draft) (point-min)))
      (should (= (overlay-end agent-shell-fontification--draft) (point-max)))
      (agent-shell-viewport-view-mode)
      (should-not agent-shell-fontification--draft))))

(ert-deftest agent-shell-faces-tool-label-roles ()
  "Tool titles, descriptions and fallback commands have distinct faces."
  (dolist (case '(("read" "file.el" nil agent-shell-tool-title)
                  ("execute" "echo hello" "Print greeting" agent-shell-tool-description)
                  ("execute" "echo hello" nil agent-shell-tool-command)))
    (let ((label (map-elt
                  (agent-shell-make-tool-call-label
                   `((:tool-calls . (("tool" . ((:kind . ,(nth 0 case))
                                               (:title . ,(nth 1 case))
                                               (:description . ,(nth 2 case)))))))
                   "tool") :title)))
      (should (eq (nth 3 case) (get-text-property 0 'font-lock-face label))))))

(ert-deftest agent-shell-faces-plan-step ()
  "Both string and structured plans style step text without replacing status."
  (dolist (plan '("Do work" [((status . "completed") (content . "Do work"))]))
    (let ((text (agent-shell--format-plan plan)))
      (should (eq 'agent-shell-plan-step
                  (get-text-property (string-match "Do work" text) 'font-lock-face text))))))

(ert-deftest agent-shell-faces-tool-code-rendering ()
  "Command and parameter faces survive rendering and repeated fontification."
  (dolist (role '(agent-shell-tool-command agent-shell-tool-input agent-shell-tool-output))
    (with-temp-buffer
      (insert (agent-shell--face-tool-content "```console
echo hello
```" role))
      (dotimes (_ 2)
        (agent-shell--render-markdown :complete t)
        (goto-char (point-min))
        (search-forward "echo hello")
        (let ((faces (get-text-property (1- (point)) 'font-lock-face)))
          (should (memq role faces))
          (should (memq 'agent-shell-markdown-source-block faces))
          (should (= 1 (seq-count (lambda (face) (eq role face)) faces))))
        (remove-text-properties (point-min) (point-max) '(face nil))))))

(ert-deftest agent-shell-faces-setup-status ()
  "Setup progress has its own face; available-model listings remain distinct."
  (cl-letf (((symbol-function 'agent-shell--update-fragment)
             (lambda (&rest args) (plist-get args :body))))
    (should (eq 'agent-shell-setup-status
                (get-text-property
                 0 'font-lock-face
                 (agent-shell--update-bootstrapping-fragment
                  :block-id "starting" :body "Creating client..."))))
    (should (eq 'agent-shell-section-body
                (get-text-property
                 0 'font-lock-face
                 (agent-shell--update-bootstrapping-fragment
                  :block-id "available_models" :body "Available models"))))))

;;; agent-shell-faces-tests.el ends here
