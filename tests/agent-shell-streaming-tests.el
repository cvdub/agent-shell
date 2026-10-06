;;; agent-shell-streaming-tests.el --- Paragraph streaming tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'agent-shell)

;;; Code:

(defmacro agent-shell-streaming-tests--with-state (&rest body)
  "Run BODY with a shell state and captured display, transcript and events."
  (declare (indent 0) (debug t))
  `(with-temp-buffer
     (let* ((agent-shell-stream-by-paragraph t)
            (state (agent-shell--make-state :buffer (current-buffer)))
            (agent-shell--state state)
            (active t)
            rendered transcript events)
       (map-put! state :active-requests '(((:method . "session/prompt"))))
       (cl-letf (((symbol-function 'agent-shell--state) (lambda () state))
                 ((symbol-function 'agent-shell--active-requests-p)
                  (lambda (_) active))
                 ((symbol-function 'agent-shell--update-fragment)
                  (lambda (&rest args) (push args rendered)))
                 ((symbol-function 'agent-shell--append-transcript)
                  (lambda (&rest args) (push (plist-get args :text) transcript)))
                 ((symbol-function 'agent-shell--emit-event)
                  (lambda (&rest args) (push args events)))
                 ((symbol-function 'agent-shell--refresh-activity-group-header) #'ignore)
                 ((symbol-function 'agent-shell--sync-activity-group-fold) #'ignore)
                 ((symbol-function 'agent-shell--cancel-idle-timer) #'ignore)
                 ((symbol-function 'agent-shell-make-tool-call-label)
                  (lambda (&rest _) '((:status . "running") (:title . "tool")))))
         ,@body))))

(cl-defun agent-shell-streaming-tests--chunk (state text &optional message-id (type "text"))
  "Send STATE a content chunk with TEXT, MESSAGE-ID and TYPE."
  (agent-shell--on-notification
   :state state
   :acp-notification
   `((method . "session/update")
     (params (update (sessionUpdate . "agent_message_chunk")
                     (messageId . ,message-id)
                     (content (type . ,type) (text . ,text)))))))

(ert-deftest agent-shell-streaming-paragraphs-test ()
  "Display complete paragraphs while delivering raw chunks to hooks."
  (agent-shell-streaming-tests--with-state
    (agent-shell-streaming-tests--chunk state "First\n")
    (should-not rendered)
    (should (equal (plist-get (car events) :data) '((:text-chunk . "First\n"))))
    (should (equal (car transcript) "First\n"))
    (agent-shell-streaming-tests--chunk state "\nSecond\n\nLast")
    (should (= (length rendered) 1))
    (should (equal (plist-get (car rendered) :body) "First\n\nSecond\n\n"))
    (should (plist-get (car rendered) :create-new))
    (should (get-text-property 0 'agent-shell-message-body (plist-get (car rendered) :body)))
    (agent-shell--flush-agent-text state)
    (should (equal (plist-get (car rendered) :body) "Last"))
    (should-not (plist-get (car rendered) :create-new))
    (should-not (map-elt state :pending-agent-text))
    (agent-shell--flush-agent-text state)
    (should (= (length rendered) 2))))

(ert-deftest agent-shell-streaming-fences-test ()
  "Keep blank lines inside split backtick and tilde fences buffered."
  (dolist (fence '("```" "~~~~"))
    (agent-shell-streaming-tests--with-state
      (dolist (char (string-to-list (concat "Intro\n\n" fence "elisp\n(a)\n\n(b)\n")))
        (agent-shell-streaming-tests--chunk state (char-to-string char)))
      (should (equal (mapcar (lambda (args) (plist-get args :body)) rendered)
                     '("Intro\n\n")))
      (agent-shell-streaming-tests--chunk state (concat fence "\nTrailing"))
      (should (equal (plist-get (car rendered) :body)
                     (concat fence "elisp\n(a)\n\n(b)\n" fence "\n")))
      (agent-shell--flush-agent-text state)
      (should (equal (plist-get (car rendered) :body) "Trailing")))))

(ert-deftest agent-shell-streaming-fence-length-test ()
  "A shorter fence cannot close an open block."
  (should-not (agent-shell--paragraph-boundary "````\nx\n\n```\n"))
  (should (= (agent-shell--paragraph-boundary "````\nx\n\n`````\n") 14))
  (should (= (agent-shell--paragraph-boundary "One\r\n \t\r\nTwo") 9)))

(ert-deftest agent-shell-streaming-message-boundary-test ()
  "Flush before a different message ID and keep the fragment IDs separate."
  (agent-shell-streaming-tests--with-state
    (agent-shell-streaming-tests--chunk state "One" "one")
    (agent-shell-streaming-tests--chunk state "Two" "two")
    (should (equal (plist-get (car rendered) :body) "One"))
    (should (equal (plist-get (car rendered) :block-id) "one-agent_message_chunk"))
    (agent-shell--flush-agent-text state)
    (should (equal (plist-get (car rendered) :body) "Two"))
    (should (equal (plist-get (car rendered) :block-id) "two-agent_message_chunk"))
    (should (seq-every-p (lambda (args) (plist-get args :create-new)) rendered))))

(ert-deftest agent-shell-streaming-tool-boundary-test ()
  "Display unfinished prose before the following tool call."
  (agent-shell-streaming-tests--with-state
    (agent-shell-streaming-tests--chunk state "Checking files")
    (agent-shell--on-notification
     :state state
     :acp-notification '((method . "session/update")
                         (params (update (sessionUpdate . "tool_call")
                                         (toolCallId . "tool-1")
                                         (title . "Read files")
                                         (kind . "read")
                                         (status . "in_progress")))))
    (should (equal (plist-get (car rendered) :block-id) "tool-1"))
    (should (equal (plist-get (cadr rendered) :body) "Checking files"))
    (should-not (map-elt state :pending-agent-text))))

(ert-deftest agent-shell-streaming-immediate-modes-test ()
  "Disabled buffering, out-of-turn messages and history display immediately."
  (agent-shell-streaming-tests--with-state
    (let ((agent-shell-stream-by-paragraph nil))
      (agent-shell-streaming-tests--chunk state "Immediate"))
    (should (equal (plist-get (car rendered) :body) "Immediate"))
    (setq active nil)
    (agent-shell-streaming-tests--chunk state "Outside turn")
    (should (equal (plist-get (car rendered) :body) "Outside turn"))
    (setq active t)
    (agent-shell--replay-turn
     state '(((method . "session/update")
              (params (update (sessionUpdate . "agent_message_chunk")
                              (content (type . "text") (text . "History")))))))
    (should (equal (plist-get (car rendered) :body) "History"))
    (should-not (map-elt state :pending-agent-text))
    (map-put! state :active-requests '(((:method . "session/load"))))
    (agent-shell-streaming-tests--chunk state "Loading history")
    (should (equal (plist-get (car rendered) :body) "Loading history"))
    (should-not (map-elt state :pending-agent-text))))

(ert-deftest agent-shell-streaming-disable-mid-message-test ()
  "Disabling the option flushes the pending paragraph before the next chunk."
  (agent-shell-streaming-tests--with-state
    (agent-shell-streaming-tests--chunk state "Held")
    (let ((agent-shell-stream-by-paragraph nil))
      (agent-shell-streaming-tests--chunk state " now"))
    (should (equal (mapcar (lambda (args) (plist-get args :body)) (reverse rendered))
                   '("Held" " now")))
    (should-not (plist-get (car rendered) :create-new))
    (should-not (map-elt state :pending-agent-text))))

(ert-deftest agent-shell-streaming-turn-end-test ()
  "Flush remaining text before completing successful, cancelled and failed turns."
  (dolist (reason '("end_turn" "cancelled" error))
    (agent-shell-streaming-tests--with-state
      (let (request
            (agent-shell-show-busy-indicator nil)
            (agent-shell-show-usage-at-turn-end nil))
        (map-put! (map-elt state :session) :id "test-session")
        (cl-letf (((symbol-function 'agent-shell--send-request)
                   (lambda (&rest args) (setq request args)))
                  ((symbol-function 'agent-shell--finish-output) #'ignore)
                  ((symbol-function 'agent-shell--render-deferred-markup) #'ignore)
                  ((symbol-function 'agent-shell--prompt-queue-process-next) #'ignore)
                  ((symbol-function 'agent-shell--prompt-queue-display) #'ignore)
                  ((symbol-function 'agent-shell--make-error-handler)
                   (lambda (&rest _) (lambda (&rest _) nil))))
          (agent-shell--send-command :prompt "Hello" :shell-buffer (current-buffer))
          (agent-shell-streaming-tests--chunk state "Unfinished")
          (if (eq reason 'error)
              (funcall (plist-get request :on-failure) '((message . "failed")) "failed")
            (funcall (plist-get request :on-success) `((stopReason . ,reason))))
          (should (seq-find (lambda (args) (equal (plist-get args :body) "Unfinished")) rendered))
          (should-not (map-elt state :pending-agent-text)))))))

(ert-deftest agent-shell-streaming-interrupt-test ()
  "Flush text when interruption is requested, before sending cancellation."
  (agent-shell-streaming-tests--with-state
    (map-put! (map-elt state :session) :id "test-session")
    (agent-shell-streaming-tests--chunk state "Partial response")
    (let ((major-mode 'agent-shell-mode)
          cancelled)
      (cl-letf (((symbol-function 'acp-send-notification)
                 (lambda (&rest _)
                   (should (equal (plist-get (car rendered) :body) "Partial response"))
                   (setq cancelled t))))
        (agent-shell-interrupt t)
        (should cancelled)
        (should-not (map-elt state :pending-agent-text))))))

(ert-deftest agent-shell-streaming-non-text-test ()
  "Non-text content flushes earlier prose and renders immediately."
  (agent-shell-streaming-tests--with-state
    (agent-shell-streaming-tests--chunk state "Look at this")
    (agent-shell--on-notification
     :state state
     :acp-notification '((method . "session/update")
                         (params (update (sessionUpdate . "agent_message_chunk")
                                         (content (type . "image")
                                                  (mimeType . "image/png")
                                                  (uri . "file:///tmp/x.png"))))))
    (should (equal (plist-get (car rendered) :body) "\n\n![image](file:///tmp/x.png)\n\n"))
    (should (equal (plist-get (cadr rendered) :body) "Look at this"))
    (should-not (map-elt state :pending-agent-text))))

(ert-deftest agent-shell-streaming-metadata-test ()
  "Session metadata updates leave incomplete paragraphs buffered."
  (agent-shell-streaming-tests--with-state
    (agent-shell-streaming-tests--chunk state "Still typing")
    (cl-letf (((symbol-function 'agent-shell--set-session-title) #'ignore))
      (agent-shell--on-notification
       :state state
       :acp-notification '((method . "session/update")
                           (params (update (sessionUpdate . "session_info_update")
                                           (title . "New title"))))))
    (should-not rendered)
    (agent-shell-streaming-tests--chunk state "\n\n")
    (should (equal (plist-get (car rendered) :body) "Still typing\n\n"))))

(provide 'agent-shell-streaming-tests)
;;; agent-shell-streaming-tests.el ends here
