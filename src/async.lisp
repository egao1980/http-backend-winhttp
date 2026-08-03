(in-package #:http-backend-winhttp)

;;; WINHTTP_FLAG_ASYNC request state machine.
;;; WinHTTP worker callbacks advance I/O; completions / stream feeds are
;;; marshaled onto event-protocol via WAKE + DEFER.

(defvar *winhttp-ctx* (make-hash-table :test #'eql)
  "Context id → WINHTTP-REQUEST-HANDLE.")
(defvar *winhttp-ctx-lock* (bt:make-lock "winhttp-ctx"))
(defvar *winhttp-ctx-id* 0)

(defclass winhttp-request-handle ()
  ((id :initarg :id :reader handle-id)
   (canceled :initform nil :accessor winhttp-request-canceled-p)
   (session :initform nil :accessor handle-session)
   (conn :initform nil :accessor handle-conn)
   (req :initform nil :accessor handle-req)
   (event-backend :initarg :event-backend :reader handle-event-backend)
   (event-loop :initarg :event-loop :reader handle-event-loop)
   (callback :initarg :callback :reader handle-callback)
   (error-callback :initarg :error-callback :reader handle-error-callback)
   (want-stream :initarg :want-stream :reader handle-want-stream-p)
   (uri :initarg :uri :accessor handle-uri)
   (method :initarg :method :accessor handle-method)
   (proxy-uri :initarg :proxy-uri :accessor handle-proxy-uri)
   (basic-auth :initarg :basic-auth :accessor handle-basic-auth)
   (content :initarg :content :accessor handle-content)
   (request :initarg :request :reader handle-http-request)
   (client :initarg :client :reader handle-client)
   (body-stream :initform nil :accessor handle-body-stream)
   (body-buf :initform nil :accessor handle-body-buf)
   (body-chunks :initform nil :accessor handle-body-chunks)
   (headers-ht :initform nil :accessor handle-headers-ht)
   (status :initform nil :accessor handle-status)
   (headers-delivered :initform nil :accessor handle-headers-delivered-p)
   (read-buf :initform nil :accessor handle-read-buf
             :documentation "Foreign buffer for async WinHttpReadData.")
   (read-buf-len :initform 65536 :reader handle-read-buf-len)
   (read-paused :initform nil :accessor handle-read-paused-p)
   (finished :initform nil :accessor handle-finished-p)
   (lock :initform (bt:make-lock "winhttp-handle") :reader handle-lock)))

(defun %register-handle (h)
  (bt:with-lock-held (*winhttp-ctx-lock*)
    (let ((id (incf *winhttp-ctx-id*)))
      (setf (slot-value h 'id) id
            (gethash id *winhttp-ctx*) h)
      id)))

(defun %unregister-handle (id)
  (bt:with-lock-held (*winhttp-ctx-lock*)
    (remhash id *winhttp-ctx*)))

(defun %find-handle (id)
  (bt:with-lock-held (*winhttp-ctx-lock*)
    (gethash id *winhttp-ctx*)))

(defun %marshal (h thunk)
  "Run THUNK on the event loop (WinHTTP callback → event-protocol)."
  (let ((eb (handle-event-backend h))
        (el (handle-event-loop h)))
    (defer eb el thunk)
    (ignore-errors (wake eb el))))

(defun %fail (h condition)
  (bt:with-lock-held ((handle-lock h))
    (when (handle-finished-p h) (return-from %fail))
    (setf (handle-finished-p h) t))
  (when-let (s (handle-body-stream h))
    (body-fail s condition))
  (%marshal h
            (lambda ()
              (ignore-errors (funcall (handle-error-callback h) condition))
              (%cleanup h))))

(defun %succeed (h response)
  (bt:with-lock-held ((handle-lock h))
    (when (handle-finished-p h) (return-from %succeed))
    (when (handle-want-stream-p h)
      ;; Stream still open — mark headers delivered; finish on body EOF.
      (setf (handle-headers-delivered-p h) t))
    (unless (handle-want-stream-p h)
      (setf (handle-finished-p h) t)))
  (%marshal h
            (lambda ()
              (ignore-errors (funcall (handle-callback h) response))
              (unless (handle-want-stream-p h)
                (%cleanup h)))))

(defun %close-hinternet (h)
  #+(or win32 windows mswindows)
  (ignore-errors (winhttp:close-handle h))
  #-(or win32 windows mswindows)
  (declare (ignore h)))

(defun %cleanup (h)
  (bt:with-lock-held ((handle-lock h))
    (when-let (buf (handle-read-buf h))
      (ignore-errors (cffi:foreign-free buf))
      (setf (handle-read-buf h) nil))
    (when-let (r (handle-req h))
      (%close-hinternet r)
      (setf (handle-req h) nil))
    (when-let (c (handle-conn h))
      (%close-hinternet c)
      (setf (handle-conn h) nil))
    (when-let (s (handle-session h))
      (%close-hinternet s)
      (setf (handle-session h) nil)))
  (%unregister-handle (handle-id h)))

(defun %close-for-cancel (h)
  "Cancel in-flight: WinHttpCloseHandle aborts async ops."
  (bt:with-lock-held ((handle-lock h))
    (setf (winhttp-request-canceled-p h) t)
    (when (handle-finished-p h) (return-from %close-for-cancel))
    (setf (handle-finished-p h) t)
    (when-let (r (handle-req h))
      (%close-hinternet r)
      (setf (handle-req h) nil)))
  (when-let (s (handle-body-stream h))
    (body-fail s (make-condition 'http-canceled :message "request canceled")))
  (%marshal h
            (lambda ()
              (ignore-errors
               (funcall (handle-error-callback h)
                        (make-condition 'http-canceled :message "request canceled")))
              (%cleanup h))))

#+ (or win32 windows mswindows)
(progn
  (defun %headers-hash (req)
    (loop with hash = (make-hash-table :test 'equal)
          for (name-camel value) in (winhttp:query-headers req)
          for name = (string-downcase name-camel)
          if (gethash name hash)
            do (setf (gethash name hash)
                     (format nil "~A, ~A" (gethash name hash) value))
          else
            do (setf (gethash name hash) value)
          finally (return hash)))

  (defun %path-query (uri)
    (format nil "~@[~A~]~@[?~A~]" (or (quri:uri-path uri) "/")
            (quri:uri-query uri)))

  (defun %ensure-read-buf (h)
    (or (handle-read-buf h)
        (setf (handle-read-buf h)
              (cffi:foreign-alloc :uint8 :count (handle-read-buf-len h)))))

  (defun %kick-read (h)
    "Issue next WinHttpReadData (async → READ_COMPLETE or sync complete)."
    (when (or (winhttp-request-canceled-p h) (handle-read-paused-p h))
      (return-from %kick-read))
    (let* ((req (handle-req h))
           (ptr (%ensure-read-buf h))
           (len (handle-read-buf-len h)))
      (handler-case
          (cffi:with-foreign-object (nread :uint32)
            (let ((ok (winhttp::%read-data req ptr len nread)))
              (cond
                (ok (%on-read-complete h ptr (cffi:mem-ref nread :uint32)))
                ((pending-p))
                (t (winhttp::get-last-error)))))
        (error (e) (%fail h e)))))

  (defun %on-read-complete (h ptr n)
    (cond
      ((zerop n)
       (when (handle-read-buf h)
         (cffi:foreign-free (handle-read-buf h))
         (setf (handle-read-buf h) nil))
       (if (handle-want-stream-p h)
           (progn
             (body-eof (handle-body-stream h))
             (bt:with-lock-held ((handle-lock h))
               (setf (handle-finished-p h) t))
             (%marshal h (lambda () (%cleanup h))))
           (let* ((octets (apply #'concatenate '(vector (unsigned-byte 8))
                                 (nreverse (handle-body-chunks h))))
                  (res (%make-response h octets)))
             (%succeed h res))))
      (t
       (let ((piece (make-array n :element-type '(unsigned-byte 8))))
         (dotimes (i n)
           (setf (aref piece i) (cffi:mem-aref ptr :uint8 i)))
         (if (handle-want-stream-p h)
             (progn
               (body-feed (handle-body-stream h) piece)
               (when (body-full-p (handle-body-stream h))
                 (setf (handle-read-paused-p h) t))
               (unless (handle-read-paused-p h)
                 (%kick-read h)))
             (progn
               (push piece (handle-body-chunks h))
               (%kick-read h)))))))

  (defun %make-response (h body)
    (let* ((req (handle-http-request h))
           (uri (handle-uri h))
           (url (quri:render-uri uri))
           (ht (handle-headers-ht h))
           (jar (resolve-cookie-jar (handle-client h) req :url url))
           (cookies (merge-response-cookies jar url ht)))
      (multiple-value-bind (body* headers*)
          (if (streamp body)
              (values body ht)
              (let* ((ce (gethash "content-encoding" ht))
                     (codings (parse-content-encoding ce))
                     (decoded (if (and codings (http-request-decompress req))
                                  (decode-content-codings codings body)
                                  body))
                     (ht2 (let ((n (make-hash-table :test #'equal)))
                            (maphash (lambda (k v) (setf (gethash k n) v)) ht)
                            (when (and codings (http-request-decompress req))
                              (remhash "content-encoding" n)
                              (remhash "content-length" n))
                            n)))
                (values decoded ht2)))
        (make-instance 'http-response
                       :status (handle-status h)
                       :headers headers*
                       :body body*
                       :url url
                       :cookies cookies
                       :request req))))

  (defun %on-headers (h)
    (let* ((req (handle-req h))
           (status (winhttp:query-status-code req))
           (ht (%headers-hash req)))
      (setf (handle-status h) status
            (handle-headers-ht h) ht)
      ;; 401/407 auth — set credentials + resend (connection-oriented).
      (when (member status '(401 407))
        (when (answer-auth-challenge req status ht
                                     (handle-uri h)
                                     (handle-proxy-uri h)
                                     (handle-basic-auth h))
          (handler-case
              (progn
                (drain-response-body req)
                (let* ((content (or (handle-content h) #()))
                       (ok (winhttp:send-request req content)))
                  (unless (or ok (pending-p))
                    (winhttp::get-last-error))))
            (error (e) (%fail h e)))
          (return-from %on-headers)))
      (if (handle-want-stream-p h)
          (let ((stream (make-winhttp-body-input-stream
                         :on-space
                         (lambda ()
                           (when (handle-read-paused-p h)
                             (setf (handle-read-paused-p h) nil)
                             (%kick-read h))))))
            (setf (handle-body-stream h) stream)
            (%succeed h (%make-response h stream))
            (%kick-read h))
          (progn
            (setf (handle-body-chunks h) nil)
            (%kick-read h)))))

  (winhttp:define-status-callback %winhttp-status-cb
      (hinternet context status infop infolen)
    (declare (ignore hinternet))
    (let* ((id (cffi:pointer-address context))
           (h (%find-handle id)))
      (unless h (return-from %winhttp-status-cb))
      (when (winhttp-request-canceled-p h) (return-from %winhttp-status-cb))
      (handler-case
          (case status
            (:sendrequest-complete
             (handler-case
                 (winhttp:receive-response (handle-req h))
               (error (e) (%fail h e))))
            (:headers-available
             (%on-headers h))
            (:data-available
             (%kick-read h))
            (:read-complete
             (%on-read-complete h
                                (or infop (handle-read-buf h))
                                infolen))
            (:request-error
             (%fail h (make-condition 'http-connection-error
                                      :message "WinHTTP REQUEST_ERROR")))
            (:handle-closing)
            (otherwise))
        (error (e) (%fail h e)))))

  (defun %start-async-request (h uri method headers content
                               &key system-proxy-p proxy-uri insecure
                                 user-agent)
    (let* ((id (%register-handle h))
           (host (strip-ipv6-brackets (quri:uri-host uri)))
           (port (or (quri:uri-port uri)
                     (if (string-equal (quri:uri-scheme uri) "https") 443 80)))
           (https (string-equal (quri:uri-scheme uri) "https"))
           (session (open-http-session (or user-agent "http-backend-winhttp/0.1")
                                       system-proxy-p :async t))
           (ctx (cffi:make-pointer id)))
      (setf (handle-session h) session
            (handle-uri h) uri
            (handle-method h) method
            (handle-content h) content
            (handle-proxy-uri h) proxy-uri)
      (winhttp:set-status-callback session (cffi:get-callback '%winhttp-status-cb))
      (let ((conn (winhttp:http-connect session host port)))
        (setf (handle-conn h) conn)
        (let ((req (winhttp:http-open-request conn
                                              :verb method
                                              :url (%path-query uri)
                                              :https-p https)))
          (setf (handle-req h) req)
          (set-option req +winhttp-option-disable-feature+
                      (logior +winhttp-disable-cookies+
                              +winhttp-disable-redirects+))
          (set-option req +winhttp-option-autologon-policy+
                      (autologon-policy-value))
          ;; Context for callbacks
          (cffi:with-foreign-object (p :pointer)
            (setf (cffi:mem-ref p :pointer) ctx)
            (winhttp::%set-option req +winhttp-option-context+ p
                                  (cffi:foreign-type-size :pointer)))
          (when proxy-uri
            (set-request-proxy req
                               (format-host-port (quri:uri-host proxy-uri)
                                                 (or (quri:uri-port proxy-uri) 80)))
            (when-let (ui (quri:uri-userinfo proxy-uri))
              (destructuring-bind (user &optional (pass ""))
                  (split-sequence #\: ui)
                (set-request-credentials req :proxy :basic user pass))))
          (dolist (hdr headers)
            (winhttp:add-request-headers
             req (format nil "~:(~A~): ~A" (car hdr) (cdr hdr))))
          (when (and https insecure)
            (ignore-errors (winhttp::set-ignore-certificates req)))
          (let* ((body (or content #()))
                 (ok (winhttp:send-request req body)))
            (unless (or ok (pending-p))
              (winhttp::get-last-error)))
          h)))))

#- (or win32 windows mswindows)
(defun %start-async-request (&rest args)
  (declare (ignore args))
  (error 'unsupported-operation :operation :winhttp
         :message "http-backend-winhttp requires Windows"))
