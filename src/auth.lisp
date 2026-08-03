(in-package #:http-backend-winhttp)

;;; Proxy/server auth (dexador#202): Basic + NTLM + Negotiate SSO.

(defvar *use-default-credentials* t
  "When T, answer Negotiate/NTLM with the logged-on user (SSO) if no explicit creds.")

(defvar *winhttp-autologon-policy* :medium
  ":MEDIUM intranet only (default); :LOW any host; :HIGH never.")

(defun autologon-policy-value ()
  (if (not *use-default-credentials*)
      +winhttp-autologon-high+
      (ecase *winhttp-autologon-policy*
        (:medium +winhttp-autologon-medium+)
        (:low +winhttp-autologon-low+)
        (:high +winhttp-autologon-high+))))

#+ (or win32 windows mswindows)
(progn
  (defun set-request-credentials (req target scheme user pass)
    "NULL USER → SSO for Negotiate/NTLM."
    (flet ((%set (u p)
             (unless (winhttp::%set-credentials
                      req
                      (ecase target (:server 0) (:proxy 1))
                      (ecase scheme
                        (:basic +winhttp-auth-basic+)
                        (:ntlm +winhttp-auth-ntlm+)
                        (:digest +winhttp-auth-digest+)
                        (:negotiate +winhttp-auth-negotiate+))
                      u p (cffi:null-pointer))
               (winhttp::get-last-error))))
      (if user
          (winhttp::with-wide-string (u user)
            (winhttp::with-wide-string (p (or pass ""))
              (%set u p)))
          (%set (cffi:null-pointer) (cffi:null-pointer)))))

  (defun query-auth-schemes (req)
    (cffi:with-foreign-objects ((supported :uint32)
                                (first :uint32)
                                (target :uint32))
      (when (%query-auth-schemes req supported first target)
        (values (cffi:mem-ref supported :uint32)
                (cffi:mem-ref first :uint32)
                (cffi:mem-ref target :uint32)))))

  (defun select-auth-scheme-from-mask (supported)
    (loop for (flag key) in `((,+winhttp-auth-negotiate+ :negotiate)
                              (,+winhttp-auth-ntlm+ :ntlm)
                              (,+winhttp-auth-digest+ :digest)
                              (,+winhttp-auth-basic+ :basic))
          when (plusp (logand supported flag))
            return key))

  (defun select-auth-scheme-from-header (challenge)
    (when challenge
      (let ((tokens (loop for part in (split-sequence #\, challenge)
                          for trimmed = (string-trim " " part)
                          collect (subseq trimmed 0 (or (position #\Space trimmed)
                                                        (length trimmed))))))
        (loop for (name key) in '(("Negotiate" :negotiate) ("NTLM" :ntlm)
                                  ("Digest" :digest) ("Basic" :basic))
              when (member name tokens :test #'string-equal)
                return key))))

  (defun userinfo-credentials (uri)
    (let ((userinfo (and uri (quri:uri-userinfo uri))))
      (when userinfo
        (let ((colon (position #\: userinfo)))
          (if colon
              (cons (subseq userinfo 0 colon) (subseq userinfo (1+ colon)))
              (cons userinfo ""))))))

  (defun drain-response-body (req)
    (let ((buffer (make-array 4096 :element-type '(unsigned-byte 8))))
      (loop for bytes = (winhttp:read-data req buffer)
            until (zerop bytes))))

  (defun answer-auth-challenge (req status response-headers uri proxy-uri basic-auth)
    "Set credentials for 401/407; T → resend. SSO when no explicit creds."
    (multiple-value-bind (supported preferred queried-target)
        (query-auth-schemes req)
      (declare (ignore preferred))
      (multiple-value-bind (target creds scheme)
          (if supported
              (let* ((target (if (= queried-target 1) :proxy :server))
                     (creds (if (eq target :proxy)
                                (userinfo-credentials proxy-uri)
                                (or (userinfo-credentials uri) basic-auth)))
                     (scheme (select-auth-scheme-from-mask supported)))
                (values target creds scheme))
              (let* ((target (if (eql status 407) :proxy :server))
                     (challenge (gethash (if (eq target :proxy)
                                             "proxy-authenticate"
                                             "www-authenticate")
                                         response-headers))
                     (creds (if (eq target :proxy)
                                (userinfo-credentials proxy-uri)
                                (or (userinfo-credentials uri) basic-auth)))
                     (scheme (select-auth-scheme-from-header challenge)))
                (values target creds scheme)))
        (when scheme
          (cond
            (creds
             (set-request-credentials req target scheme (car creds) (cdr creds))
             t)
            ((and *use-default-credentials* (member scheme '(:negotiate :ntlm)))
             (set-request-credentials req target scheme nil nil)
             t)))))))

#- (or win32 windows mswindows)
(defun answer-auth-challenge (&rest args)
  (declare (ignore args))
  nil)
