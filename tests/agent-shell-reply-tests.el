;;; agent-shell-reply-tests.el --- Split replies -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'agent-shell)

(defmacro agent-shell-reply-test-with-viewport (&rest body)
  "Exercise real viewport commands with an isolated shell and fake transport."
  (declare (indent 0))
  `(save-window-excursion
     (let* ((shell (generate-new-buffer "reply-test"))
            (viewport (get-buffer-create (concat (buffer-name shell) " [viewport]")))
            (agent-shell-viewport--clean-up nil)
            (agent-shell-viewport-dismiss-on-send nil)
            (agent-shell-session-strategy 'new)
            (agent-shell-header-style 'graphical)
            (agent-shell-prefer-viewport-interaction t)
            (sent nil))
       (unwind-protect
           (cl-letf (((symbol-function 'agent-shell--make-header)
                      (lambda (&rest _) "Full agent header"))
                     ((symbol-function 'agent-shell--project-name) (lambda () "dotfiles"))
                     ((symbol-function 'agent-shell-viewport--position)
                      (lambda (&rest _) '((:current . 1) (:total . 1))))
                     ((symbol-function 'agent-shell-viewport--busy-p) (lambda () nil))
                     ((symbol-function 'agent-shell--insert-to-shell-buffer)
                      (lambda (&rest args)
                        (setq sent (plist-get args :text))
                        ;; Model the transport updating the canonical viewport.
                        (with-current-buffer viewport
                          (agent-shell-viewport--initialize
                           :prompt sent :response "\nNew turn response"))))
                     ((symbol-function 'shell-maker-history-position) (lambda () 1))
                     ((symbol-function 'agent-shell-goto-last-interaction) #'ignore)
                     ((symbol-function 'agent-shell-interaction-at-point)
                      (lambda () '((:prompt . "Question\n\n")
                                   (:response . "Response to consult\n- Detail\n")))))
             (with-current-buffer shell
               (setq-local major-mode 'agent-shell-mode)
               (setq-local agent-shell--state '((:session . ((:id . "test"))))))
             (delete-other-windows)
             (switch-to-buffer viewport)
             (agent-shell-viewport-view-mode)
             (agent-shell-viewport--initialize
              :prompt "Question\n\n" :response "Response to consult\n- Detail\n")
             ,@body)
         (when (buffer-live-p viewport)
           (with-current-buffer viewport (agent-shell-reply--close))
           (kill-buffer viewport))
         (dolist (buffer (buffer-list))
           (when (eq (buffer-local-value 'agent-shell-reply--shell buffer) shell)
             (kill-buffer buffer)))
         (kill-buffer shell)))))

(ert-deftest agent-shell-reply-split-send ()
  (agent-shell-reply-test-with-viewport
    (let ((response (buffer-string))
          (height (window-total-height))
          (header header-line-format))
      (agent-shell-viewport-reply)
      (should (= 2 (length (window-list))))
      (should (derived-mode-p 'agent-shell-viewport-edit-mode))
      (should agent-shell-list-edit-mode)
      (should agent-shell-reply-mode)
      (should-not (eq (current-buffer) viewport))
      (should (eq (agent-shell-viewport--buffer :shell-buffer shell) viewport))
      (should (= (window-total-height) (max window-min-height (/ height 3))))
      ;; Activity/header refreshes must not replace the compact reply header.
      (agent-shell-viewport--update-header)
      (should (equal (eval (cadr header-line-format) t)
                     " 1/1 ➤ dotfiles ➤ reply-test"))
      (let ((reference (map-elt agent-shell-reply--layout :viewport))
            (reply (current-buffer)))
        (should (eq reference viewport))
        (with-current-buffer viewport
          (should (derived-mode-p 'agent-shell-viewport-view-mode))
          (should-not agent-shell-reply-mode))
        (should (equal (buffer-local-value 'header-line-format reference) header))
        (should (equal response (with-current-buffer reference (buffer-string))))
        (should (buffer-local-value 'buffer-read-only reference))
        (should (> (nth 1 (window-edges (selected-window)))
                   (nth 1 (window-edges (map-elt agent-shell-reply--layout :upper)))))
        (insert "1. First")
        (agent-shell-list-edit-newline)
        (insert "Second")
        (when (and (display-graphic-p) (getenv "EMACS_TEST_ARTIFACTS"))
          (redisplay t)
          (sleep-for 0.2)
          (should (zerop (call-process
                          "grim" nil nil nil
                          (expand-file-name "reply-split.png"
                                            (getenv "EMACS_TEST_ARTIFACTS"))))))
        (agent-shell-viewport-compose-send)
        (should (equal sent "1. First\n2. Second"))
        (should (= 1 (length (window-list))))
        (should (eq (window-buffer) viewport))
        (should (derived-mode-p 'agent-shell-viewport-view-mode))
        (should (string-match-p "New turn response" (buffer-string)))
        (should (equal header-line-format "Full agent header"))
        (should (buffer-live-p reference))
        (should-not (buffer-live-p reply))
        (when (and (display-graphic-p) (getenv "EMACS_TEST_ARTIFACTS"))
          (redisplay t)
          (sleep-for 0.2)
          (should (zerop (call-process
                          "grim" nil nil nil
                          (expand-file-name "reply-submitted.png"
                                            (getenv "EMACS_TEST_ARTIFACTS"))))))))))

(ert-deftest agent-shell-reply-empty-send-and-cancel ()
  (agent-shell-reply-test-with-viewport
    (agent-shell-viewport-reply)
    (should-error (agent-shell-viewport-compose-send) :type 'user-error)
    (should (= 2 (length (window-list))))
    (insert "Keep this draft")
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) nil)))
      (agent-shell-viewport-compose-cancel))
    (should (= 2 (length (window-list))))
    (should (string-match-p "Keep this draft" (buffer-string)))
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
      (agent-shell-viewport-compose-cancel))
    (should (= 1 (length (window-list))))
    (should (string-match-p "Response to consult" (buffer-string)))))

(ert-deftest agent-shell-reply-quote-and-preserve-other-windows ()
  (agent-shell-reply-test-with-viewport
    (let* ((other (split-window-right))
           (other-buffer (get-buffer-create " *reply unrelated*")))
      (unwind-protect
          (progn
            (set-window-buffer other other-buffer)
            (agent-shell-viewport-quote-reply)
            (should (string-match-p "> Response to consult" (buffer-string)))
            (agent-shell-viewport-compose-send)
            (should (= 2 (length (window-list))))
            (should (eq (window-buffer other) other-buffer)))
        (kill-buffer other-buffer)))))

(ert-deftest agent-shell-reply-send-keep-composing ()
  (agent-shell-reply-test-with-viewport
    (agent-shell-viewport-reply)
    (insert "Follow up")
    (agent-shell-viewport-compose-send t)
    (should (equal sent "Follow up"))
    (should (= 2 (length (window-list))))
    (should (derived-mode-p 'agent-shell-viewport-edit-mode))))

(ert-deftest agent-shell-reply-transport-error-preserves-draft ()
  (agent-shell-reply-test-with-viewport
    (agent-shell-viewport-reply)
    (insert "Preserve this reply")
    (cl-letf (((symbol-function 'agent-shell--insert-to-shell-buffer)
               (lambda (&rest _) (error "Disconnected"))))
      (should-error (agent-shell-viewport-compose-send)))
    (should (derived-mode-p 'agent-shell-viewport-edit-mode))
    (should (string-match-p "Preserve this reply" (buffer-string)))
    (should (= 2 (length (window-list))))))

(ert-deftest agent-shell-reply-busy-queue-collapses ()
  (agent-shell-reply-test-with-viewport
    (agent-shell-viewport-reply)
    (insert "Next turn")
    (cl-letf (((symbol-function 'agent-shell-viewport--busy-p) (lambda () t))
              ((symbol-function 'agent-shell--busy-submit)
               (lambda (&rest args) (setq sent (plist-get args :prompt)))))
      (agent-shell-viewport-compose-send))
    (should (equal sent "Next turn"))
    (should (= 1 (length (window-list))))
    (should (derived-mode-p 'agent-shell-viewport-view-mode))))

(ert-deftest agent-shell-reply-peek-does-not-add-another-split ()
  (agent-shell-reply-test-with-viewport
    (agent-shell-viewport-reply)
    (insert "Draft before peeking")
    (agent-shell-viewport-compose-peek-last)
    (agent-shell-viewport-reply)
    (should (= 2 (length (window-list))))
    (should (string-match-p "Draft before peeking" (buffer-string)))
    (agent-shell-viewport-compose-send)
    (should (equal sent "Draft before peeking"))
    (should (= 1 (length (window-list))))))

(ert-deftest agent-shell-reply-header-is-isolated-from-normal-viewport ()
  (agent-shell-reply-test-with-viewport
    (agent-shell-viewport-reply)
    (let ((reply (current-buffer)))
      ;; Opening the normal viewport's composer must not inherit the small
      ;; reply editor's identity, draft, layout, or header.
      (with-current-buffer viewport
        (agent-shell-viewport-edit-mode)
        (agent-shell-viewport--update-header)
        (should-not agent-shell-reply-mode)
        (should-not agent-shell-reply--shell)
        (should-not agent-shell-reply--layout)
        (should (equal header-line-format "Full agent header")))
      (should (eq (agent-shell-viewport--shell-buffer reply) shell))
      (should agent-shell-reply-mode)
      (should (equal (eval (cadr header-line-format) t)
                     " 1/1 ➤ dotfiles ➤ reply-test")))))


(ert-deftest agent-shell-reply-compose-settings-and-override ()
  (dolist (dismiss '(nil t))
    (agent-shell-reply-test-with-viewport
      (let ((agent-shell-viewport-dismiss-on-send dismiss)
            (agent-shell-prefer-viewport-interaction nil))
        (agent-shell-viewport-reply)
        (insert "Send with override")
        (agent-shell-viewport-compose-send-override)
        (should (equal sent "Send with override"))
        (should (= 1 (length (window-list))))
        (should (eq (window-buffer) viewport))
        (agent-shell-viewport-reply)
        (insert "Cancel this")
        (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
          (agent-shell-viewport-compose-cancel))
        (should (= 1 (length (window-list))))
        (should (eq (window-buffer) viewport))))))

(ert-deftest agent-shell-reply-dead-session-preserves-draft ()
  (agent-shell-reply-test-with-viewport
    (agent-shell-viewport-reply)
    (insert "Preserve exactly once")
    (kill-buffer shell)
    (should-error (agent-shell-viewport-compose-send) :type 'user-error)
    (should (equal (buffer-string) "Preserve exactly once"))
    (should (derived-mode-p 'agent-shell-viewport-edit-mode))
    (should (= 2 (length (window-list))))))

(ert-deftest agent-shell-reply-failed-split-preserves-viewport ()
  (agent-shell-reply-test-with-viewport
    (let ((content (buffer-string))
          (buffers (buffer-list)))
      (cl-letf (((symbol-function 'split-window)
                 (lambda (&rest _) (error "Cannot split"))))
        (should-error (agent-shell-viewport-reply)))
      (should (eq (current-buffer) viewport))
      (should (equal (buffer-string) content))
      (should (equal (buffer-list) buffers))
      (should (= 1 (length (window-list)))))))

(ert-deftest agent-shell-reply-region-and-kill-cleanup ()
  (agent-shell-reply-test-with-viewport
    (goto-char (point-min))
    (search-forward "Response to consult")
    (set-mark (- (point) (length "Response to consult")))
    (let ((transient-mark-mode t))
      (activate-mark)
      (call-interactively (key-binding (kbd "r"))))
    (should (string-match-p "> Response to consult" (buffer-string)))
    (kill-buffer (current-buffer))
    (should (= 1 (length (window-list))))
    (should (eq (window-buffer) viewport))))

(ert-deftest agent-shell-reply-cancel-without-history ()
  (agent-shell-reply-test-with-viewport
    (agent-shell-viewport-reply)
    (insert "Discard this draft")
    (cl-letf (((symbol-function 'shell-maker-history-position) (lambda () nil))
              ((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
      (agent-shell-viewport-compose-cancel))
    (should (= 1 (length (window-list))))
    (should (eq (window-buffer) viewport))))

(ert-deftest agent-shell-reply-orphan-does-not-break-buffer-listing ()
  (agent-shell-reply-test-with-viewport
    (agent-shell-viewport-reply)
    (let ((reply (current-buffer))
          (other (generate-new-buffer "reply-test-other")))
      (unwind-protect
          (progn
            (with-current-buffer other
              (setq-local major-mode 'agent-shell-mode)
              (setq-local shell-maker--config '((:name . "test"))))
            ;; Model a reply that outlived its shell.
            (with-current-buffer reply
              (setq agent-shell-reply--shell (generate-new-buffer "dead-shell"))
              (kill-buffer agent-shell-reply--shell))
            (should (memq other (agent-shell-buffers)))
            (with-current-buffer reply
              (should-error (agent-shell-viewport--shell-buffer)
                            :type 'user-error)))
        (kill-buffer other)))))

(ert-deftest agent-shell-reply-killed-with-shell ()
  (agent-shell-reply-test-with-viewport
    (agent-shell-viewport-reply)
    (let ((reply (current-buffer)))
      (cl-letf (((symbol-function 'agent-shell--cancel-idle-timer) #'ignore)
                ((symbol-function 'agent-shell--emit-event) #'ignore)
                ((symbol-function 'agent-shell--shutdown) #'ignore))
        (with-current-buffer shell
          (agent-shell--clean-up)))
      (should-not (buffer-live-p reply)))))

;;; agent-shell-reply-tests.el ends here
