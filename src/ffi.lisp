(in-package #:http-backend-winhttp)

;;; WinHTTP FFI beyond QL winhttp: ASYNC open, AUTOMATIC_PROXY, auth, options.

(defun winhttp-available-p ()
  #+(or win32 windows mswindows) t
  #-(or win32 windows mswindows) nil)

(defconstant +winhttp-flag-async+ #x10000000)
(defconstant +winhttp-option-disable-feature+ 63)
(defconstant +winhttp-disable-cookies+ #x00000001)
(defconstant +winhttp-disable-redirects+ #x00000002)
(defconstant +winhttp-disable-keep-alive+ #x00000008)
(defconstant +winhttp-option-proxy+ 38)
(defconstant +winhttp-option-context+ 2)
(defconstant +winhttp-option-autologon-policy+ 77)
(defconstant +winhttp-autologon-medium+ 0)
(defconstant +winhttp-autologon-low+ 1)
(defconstant +winhttp-autologon-high+ 2)
(defconstant +winhttp-access-no-proxy+ 1)
(defconstant +winhttp-access-named-proxy+ 3)
(defconstant +winhttp-access-automatic-proxy+ 4)
(defconstant +winhttp-auth-basic+ 1)
(defconstant +winhttp-auth-ntlm+ 2)
(defconstant +winhttp-auth-digest+ 8)
(defconstant +winhttp-auth-negotiate+ 16)
(defconstant +error-invalid-parameter+ 87)
(defconstant +error-io-pending+ 997)
;;; WinHttpSendRequest dwTotalLength when body length is unknown (chunked).
(defconstant +winhttp-ignore-request-total-length+ #xffffffff)

#+ (or win32 windows mswindows)
(progn
  (cffi:defcstruct winhttp-proxy-info
    (access-type :uint32)
    (proxy :pointer)
    (bypass :pointer))

  (cffi:defcfun (%query-auth-schemes "WinHttpQueryAuthSchemes" :convention :stdcall)
      :boolean
    (hreq :pointer)
    (supported-schemes :pointer)
    (first-scheme :pointer)
    (auth-target :pointer))

  (cffi:defcfun (%write-data "WinHttpWriteData" :convention :stdcall) :boolean
    (hreq :pointer)
    (buffer :pointer)
    (to-write :uint32)
    (written :pointer))

  (defun open-session (user-agent access-type &key (async t))
    (winhttp::with-wide-string (u user-agent)
      (let ((h (winhttp::%http-open u access-type
                                    (cffi:null-pointer) (cffi:null-pointer)
                                    (if async +winhttp-flag-async+ 0))))
        (when (cffi:null-pointer-p h)
          (winhttp::get-last-error))
        h)))

  (defun open-http-session (user-agent system-proxy-p &key (async t))
    (if system-proxy-p
        (handler-case (open-session user-agent +winhttp-access-automatic-proxy+
                                    :async async)
          (winhttp::win-error (e)
            (if (= (winhttp::win-error-code e) +error-invalid-parameter+)
                (open-session user-agent +winhttp-access-no-proxy+ :async async)
                (error e))))
        (open-session user-agent +winhttp-access-no-proxy+ :async async)))

  (defun set-option (req var value &optional (type :uint32))
    (cffi:with-foreign-object (buf type)
      (setf (cffi:mem-aref buf type) value)
      (unless (winhttp::%set-option req var buf (cffi:foreign-type-size type))
        (winhttp::get-last-error))))

  (defun set-request-proxy (req proxy-hostport)
    (winhttp::with-wide-string (p proxy-hostport)
      (cffi:with-foreign-object (info '(:struct winhttp-proxy-info))
        (setf (cffi:foreign-slot-value info '(:struct winhttp-proxy-info) 'access-type)
              +winhttp-access-named-proxy+
              (cffi:foreign-slot-value info '(:struct winhttp-proxy-info) 'proxy) p
              (cffi:foreign-slot-value info '(:struct winhttp-proxy-info) 'bypass)
              (cffi:null-pointer))
        (unless (winhttp::%set-option req +winhttp-option-proxy+ info
                                      (cffi:foreign-type-size
                                       '(:struct winhttp-proxy-info)))
          (winhttp::get-last-error)))))

  (defun pending-p ()
    "True if last WinHTTP call returned ERROR_IO_PENDING."
    (= (cffi:foreign-funcall "GetLastError" :uint32) +error-io-pending+))

  (defun send-request-total (hreq total-length &optional (optional #()))
    "WinHttpSendRequest with explicit dwTotalLength (body via WriteData when optional empty)."
    (let* ((seq (or optional #()))
           (count (length seq)))
      (if (zerop count)
          (let ((ok (winhttp::%send-request
                     hreq (cffi:null-pointer) 0
                     (cffi:null-pointer) 0
                     total-length
                     (cffi:null-pointer))))
            (unless (or ok (pending-p))
              (winhttp::get-last-error))
            ok)
          ;; Vector path with explicit total (normally total = count).
          (cffi:with-foreign-object (buf :uint8 count)
            (dotimes (i count)
              (setf (cffi:mem-aref buf :uint8 i) (aref seq i)))
            (let ((ok (winhttp::%send-request
                       hreq (cffi:null-pointer) 0
                       buf count total-length
                       (cffi:null-pointer))))
              (unless (or ok (pending-p))
                (winhttp::get-last-error))
              ok)))))

  (defun write-data (hreq foreign-buf nbytes)
    "WinHttpWriteData. FOREIGN-BUF must stay live until WRITE_COMPLETE when async.
     Returns T on sync complete, NIL when pending (or raises on hard error)."
    (cffi:with-foreign-object (written :uint32)
      (let ((ok (%write-data hreq foreign-buf nbytes written)))
        (cond
          (ok t)
          ((pending-p) nil)
          (t (winhttp::get-last-error)))))))

#- (or win32 windows mswindows)
(progn
  (defun open-http-session (&rest args)
    (declare (ignore args))
    (error 'unsupported-operation :operation :winhttp
           :message "http-backend-winhttp requires Windows"))
  (defun set-option (&rest args)
    (declare (ignore args))
    (error 'unsupported-operation :operation :winhttp
           :message "http-backend-winhttp requires Windows"))
  (defun set-request-proxy (&rest args)
    (declare (ignore args))
    (error 'unsupported-operation :operation :winhttp
           :message "http-backend-winhttp requires Windows"))
  (defun pending-p () nil)
  (defun send-request-total (&rest args)
    (declare (ignore args))
    (error 'unsupported-operation :operation :winhttp
           :message "http-backend-winhttp requires Windows"))
  (defun write-data (&rest args)
    (declare (ignore args))
    (error 'unsupported-operation :operation :winhttp
           :message "http-backend-winhttp requires Windows")))
