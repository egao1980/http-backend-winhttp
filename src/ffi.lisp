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
;;; MSDN option-flags: WINHTTP_OPTION_ENABLE_HTTP_PROTOCOL / HTTP_PROTOCOL_USED.
(defconstant +winhttp-option-enable-http-protocol+ 133)
(defconstant +winhttp-option-http-protocol-used+ 134)
(defconstant +winhttp-protocol-flag-http2+ #x1)
(defconstant +error-invalid-parameter+ 87)
(defconstant +error-io-pending+ 997)
;;; WinHttpSendRequest dwTotalLength when body length is unknown (chunked).
(defconstant +winhttp-ignore-request-total-length+ #xffffffff)

(defun http-protocol-flags-to-version (flags)
  "Map WINHTTP_OPTION_HTTP_PROTOCOL_USED bitfield → :http/1.1 | :http/2."
  (if (plusp (logand (or flags 0) +winhttp-protocol-flag-http2+))
      :http/2
      :http/1.1))

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

  (cffi:defcfun (%query-option "WinHttpQueryOption" :convention :stdcall) :boolean
    (hreq :pointer)
    (option :uint32)
    (buf :pointer)
    (len :pointer))

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

  (defun query-option-uint32 (req option)
    "WinHttpQueryOption → DWORD. Signals on failure."
    (cffi:with-foreign-objects ((buf :uint32)
                                (len :uint32))
      (setf (cffi:mem-ref len :uint32) (cffi:foreign-type-size :uint32))
      (unless (%query-option req option buf len)
        (winhttp::get-last-error))
      (cffi:mem-ref buf :uint32)))

  (defun enable-http2 (req)
    "WINHTTP_OPTION_ENABLE_HTTP_PROTOCOL ← HTTP2 flag."
    (set-option req +winhttp-option-enable-http-protocol+
                +winhttp-protocol-flag-http2+))

  (defun http-protocol-used (req)
    "Map WINHTTP_OPTION_HTTP_PROTOCOL_USED → :http/1.1 | :http/2.
     Falls back to :http/1.1 when the option is unavailable."
    (handler-case
        (http-protocol-flags-to-version
         (query-option-uint32 req +winhttp-option-http-protocol-used+))
      (error () :http/1.1)))

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
  (defun query-option-uint32 (&rest args)
    (declare (ignore args))
    (error 'unsupported-operation :operation :winhttp
           :message "http-backend-winhttp requires Windows"))
  (defun enable-http2 (&rest args)
    (declare (ignore args))
    (error 'unsupported-operation :operation :winhttp
           :message "http-backend-winhttp requires Windows"))
  (defun http-protocol-used (&rest args)
    (declare (ignore args))
    :http/1.1)
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

(defun maybe-enable-http2 (req preference)
  "Enable WinHTTP HTTP/2 when PREFERENCE is :auto or :http/2.
   :http/1.1 leaves the default (HTTP/1.x only).
   On enable failure: ignore for :auto; signal for forced :http/2."
  (let ((pref (normalize-http-version preference)))
    (ecase pref
      (:http/1.1 nil)
      ((:auto :http/2)
       (handler-case
           (enable-http2 req)
         (error (e)
           (declare (ignore e))
           (when (eq pref :http/2)
             (error 'http-version-not-available
                    :requested :http/2
                    :negotiated nil
                    :message "WinHTTP could not enable HTTP/2"))))))))

(defun negotiated-http-version (req preference &key (backend-name "winhttp"))
  "Query negotiated version and enforce PREFERENCE via ensure-http-version-available."
  (let* ((pref (normalize-http-version preference))
         (got (or (ignore-errors (http-protocol-used req)) :http/1.1)))
    (ensure-http-version-available pref got :backend-name backend-name)))
