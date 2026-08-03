;;;; Phase 1: fetch OCI deps. Do NOT ASDF-load / ql:quickload mid-flight
;;;; while still pulling from GHCR (cffi/cl+ssl breaks dexador HTTPS).
;;;; Bootstrap: oras-pulled cl-repository-client on CL_SOURCE_REGISTRY (see MEMORY).

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

(defparameter *ci-ql-sources*
  '(("babel" :ql)
    ("trivial-features" :ql)
    ("cl-unicode" :ql))
  "QL pins: babel already bootstrapped; cl-unicode OCI v0.1.6 lacks idna-mapping.")

(cl-repo:add-registry "https://ghcr.io" :namespace "egao1980/cl-systems" :priority :prepend)

(defun ci-newest-tag (oci-name)
  "Newest version tag on ghcr.io/egao1980/cl-systems/NAME (excludes 'latest')."
  (let* ((token (or (uiop:getenv "GITHUB_TOKEN") (uiop:getenv "GH_TOKEN")))
         (auth (when token
                 (cl-oci-client/auth:make-auth-config
                  :username (or (uiop:getenv "GITHUB_ACTOR") "x-access-token")
                  :password token)))
         (reg (cl-oci-client/registry:make-registry "https://ghcr.io" :auth auth))
         (repo (format nil "egao1980/cl-systems/~a" oci-name))
         (tags (cl-oci-client/content-discovery:list-tags reg repo))
         (version-tags (remove "latest" tags :test #'string=)))
    (or (cl-repository-client/version-utils:select-preferred-version version-tags)
        (first tags)
        (error "ci-newest-tag: no tags for ~a" oci-name))))

(defun ci-install (oci-name &key version)
  (let ((version (or version (ci-newest-tag oci-name))))
    (format t "~&; ci: install ~a:~a~%" oci-name version)
    (cl-repository-client/installer:install-system
     "https://ghcr.io" (format nil "egao1980/cl-systems/~a" oci-name) version)
    (cl-repository-client/asdf-integration:configure-asdf-source-registry)
    version))

(defun ci-on-disk-p (name)
  (cl-repository-client/quickload::system-already-installed-p name))

(defun ci-fetch (name &key version)
  "Resolve + install NAME without ASDF-load or ql:quickload."
  (format t "~&; ci: fetch ~a~@[:~a~]~%" name version)
  (cl-repository-client/source-policy:call-with-policy-overrides
   *ci-ql-sources* nil nil nil
   (lambda ()
     (cl-repository-client/protected-systems:ensure-snapshot)
     (cl-repository-client/digest-cache:load-digest-cache)
     (let ((plan (cl-repository-client/quickload::compute-install-plan
                  (list name) :version version)))
       (dolist (entry plan)
         (let ((n (car entry))
               (ver (cdr entry)))
           (unless (or (cl-repository-client/source-policy:system-denied-p n)
                       (and (ci-on-disk-p n)
                            (let ((iv (cl-repository-client/quickload::installed-system-version n)))
                              (and iv (string= iv (princ-to-string ver))))))
             (format t "~&; ci: ensure-installed ~a~@[:~a~]~%" n ver)
             (let ((result (cl-repository-client/quickload::ensure-system-installed
                            n :version ver)))
               (when result
                 (cl-repository-client/asdf-integration:configure-asdf-source-registry))))))
       (when cl-repository-client/quickload::*missing-deps-accumulator*
         (format t "~&; ci: deferring ql fallback: ~{~a~^, ~}~%"
                 cl-repository-client/quickload::*missing-deps-accumulator*)))))
  (cl-repository-client/asdf-integration:configure-asdf-source-registry)
  (unless (ci-on-disk-p name)
    (error "ci-fetch: ~a not on disk after install" name)))

(call-with-ci-muffles
 (lambda ()
   ;; GHCR pulls before any ql:quickload that may load cffi.
   (ci-fetch "http-protocol")
   (ci-fetch "event-protocol")
   (ci-fetch "quri")
   (ci-fetch "alexandria")
   (ci-fetch "cffi")
   (dolist (n '("rove" "babel" "bordeaux-threads" "cl-base64"
                "split-sequence" "trivial-gray-streams" "winhttp"))
     (unless (or (ci-on-disk-p n) (asdf:find-system n nil))
       (format t "~&; ci: ql fallback ~a~%" n)
       (ql:quickload n :silent t)))))

(format t "~&; ci: install phase done~%")
(uiop:quit 0)
