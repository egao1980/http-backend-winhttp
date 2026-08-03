;;;; Phase 2: fresh image, configure ASDF from cl-repo install, run tests.

(setf *debugger-hook*
      (lambda (c h)
        (declare (ignore h))
        (format *error-output* "~&UNHANDLED: ~A~%" c)
        (uiop:quit 1)))

(setf asdf:*compile-file-failure-behaviour* :warn)

(defun call-with-ci-muffles (fn)
  #+sbcl
  (handler-bind ((sb-ext:defconstant-uneql
                  (lambda (c)
                    (declare (ignore c))
                    (let ((r (find-restart 'continue)))
                      (when r (invoke-restart r))))))
    (funcall fn))
  #-sbcl
  (funcall fn))

(call-with-ci-muffles (lambda () (asdf:load-system "cl-repository-client")))

(cl-repository-client/asdf-integration:configure-asdf-source-registry)
(cl-repository-client/asdf-integration:load-system-init-files)

(call-with-ci-muffles
 (lambda ()
   ;; Phase-1 QL does not persist into this fresh image — re-ql unpublished.
   (dolist (n '("rove" "babel" "bordeaux-threads" "cl-base64"
                "split-sequence" "trivial-gray-streams" "cffi" "winhttp"
                "blackbird" "cl-unicode"))
     (unless (asdf:find-system n nil)
       (format t "~&; ci: ql fallback ~a~%" n)
       (ql:quickload n :silent t)))
   (asdf:load-system "http-protocol")
   (asdf:load-system "event-protocol")
   (asdf:load-system "http-backend-winhttp")
   (asdf:test-system "http-backend-winhttp")))

(uiop:quit 0)
