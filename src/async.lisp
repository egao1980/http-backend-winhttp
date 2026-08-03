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
   (headers :initarg :headers :accessor handle-headers :initform nil)
   (proxy-uri :initarg :proxy-uri :accessor handle-proxy-uri)
   (system-proxy-p :initarg :system-proxy-p :accessor handle-system-proxy-p
                   :initform nil)
   (insecure :initarg :insecure :accessor handle-insecure-p :initform nil)
   (user-agent :initarg :user-agent :accessor handle-user-agent :initform nil)
   (basic-auth :initarg :basic-auth :accessor handle-basic-auth)
   (content :initarg :content :accessor handle-content :initform nil)
   (stream-body-p :initarg :stream-body-p :accessor handle-stream-body-p
                  :initform nil)
   (chunked-p :initarg :chunked-p :accessor handle-chunked-p :initform nil)
   (content-length :initarg :content-length :accessor handle-content-length
                   :initform nil)
   (body-stream-src :initarg :body-stream-src :accessor handle-body-stream-src
                    :initform nil
                    :documentation "Lisp input stream for upload WriteData.")
   (upload-read-buf :initform nil :accessor handle-upload-read-buf)
   (upload-frame :initform nil :accessor handle-upload-frame)
   (upload-pos :initform 0 :accessor handle-upload-pos)
   (upload-foreign :initform nil :accessor handle-upload-foreign
                   :documentation "Pinned buffer for in-flight WriteData.")
   (upload-done-p :initform nil :accessor handle-upload-done-p)
   (writing-body-p :initform nil :accessor handle-writing-body-p)
   (accept-encoding :initarg :accept-encoding :accessor handle-accept-encoding
                    :initform nil)
   (cookie-jar :initarg :cookie-jar :accessor handle-cookie-jar :initform nil)
   (max-redirects :initarg :max-redirects :accessor handle-max-redirects
                  :initform 5)
   (redirect-hops :initform 0 :accessor handle-redirect-hops)
   (history :initform nil :accessor handle-history)
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
   (read-buf-len :initform nil :accessor handle-read-buf-len)
   (read-paused :initform nil :accessor handle-read-paused-p)
   (finished :initform nil :accessor handle-finished-p)
   (lock :initform (bt:make-lock "winhttp-handle") :reader handle-lock)))

(defun %upload-buf-size ()
  (or (ignore-errors *http-stream-buffer-size*) 65536))

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

(defun %free-upload-foreign (h)
  (when-let (buf (handle-upload-foreign h))
    (ignore-errors (cffi:foreign-free buf))
    (setf (handle-upload-foreign h) nil)))

(defun %cleanup (h)
  (bt:with-lock-held ((handle-lock h))
    (when-let (buf (handle-read-buf h))
      (ignore-errors (cffi:foreign-free buf))
      (setf (handle-read-buf h) nil))
    (%free-upload-foreign h)
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
    (unless (handle-read-buf-len h)
      (setf (handle-read-buf-len h) (%upload-buf-size)))
    (or (handle-read-buf h)
        (setf (handle-read-buf h)
              (cffi:foreign-alloc :uint8 :count (handle-read-buf-len h)))))

  (defun %ensure-upload-read-buf (h)
    (or (handle-upload-read-buf h)
        (setf (handle-upload-read-buf h)
              (make-array (%upload-buf-size)
                          :element-type '(unsigned-byte 8)))))

  (defun %load-upload-frame (h)
    "Fill UPLOAD-FRAME from body stream. NIL = raw-length EOF (receive next)."
    (let* ((src (or (handle-body-stream-src h) (handle-content h)))
           (buf (%ensure-upload-read-buf h))
           (n (read-sequence buf src)))
      (setf (handle-upload-pos h) 0
            (handle-upload-frame h)
            (cond
              ((plusp n)
               (if (handle-chunked-p h)
                   (make-chunk-frame buf :end n)
                   (subseq buf 0 n)))
              ((handle-chunked-p h)
               (setf (handle-upload-done-p h) t)
               +chunked-terminator+)
              (t
               (setf (handle-upload-done-p h) t)
               nil)))))

  (defun %begin-receive (h)
    (setf (handle-writing-body-p h) nil)
    (%free-upload-foreign h)
    (handler-case
        (winhttp:receive-response (handle-req h))
      (error (e) (%fail h e))))

  (defun %issue-write (h)
    "Write remaining UPLOAD-FRAME via WinHttpWriteData."
    (let* ((frame (handle-upload-frame h))
           (pos (handle-upload-pos h))
           (n (- (length frame) pos)))
      (when (zerop n)
        (return-from %issue-write (%kick-write h)))
      (%free-upload-foreign h)
      (let ((ptr (cffi:foreign-alloc :uint8 :count n)))
        (setf (handle-upload-foreign h) ptr)
        (dotimes (i n)
          (setf (cffi:mem-aref ptr :uint8 i) (aref frame (+ pos i))))
        (handler-case
            (when (write-data (handle-req h) ptr n)
              ;; Sync complete (unusual for ASYNC session).
              (%on-write-complete h n))
          (error (e) (%fail h e))))))

  (defun %kick-write (h)
    "Pump next upload frame, or RECEIVE_RESPONSE when body is done."
    (when (or (winhttp-request-canceled-p h) (handle-finished-p h))
      (return-from %kick-write))
    (setf (handle-writing-body-p h) t)
    (when (and (handle-upload-frame h)
               (< (handle-upload-pos h) (length (handle-upload-frame h))))
      (return-from %kick-write (%issue-write h)))
    (let ((frame (%load-upload-frame h)))
      (if frame
          (%issue-write h)
          (%begin-receive h))))

  (defun %on-write-complete (h nbytes)
    "Advance upload after WRITE_COMPLETE (or sync WriteData)."
    (incf (handle-upload-pos h) nbytes)
    (%free-upload-foreign h)
    (let* ((frame (handle-upload-frame h))
           (frame-done (or (null frame)
                           (>= (handle-upload-pos h) (length frame))))
           (final-p (handle-upload-done-p h)))
      (cond
        ((not frame-done)
         (%issue-write h))
        (final-p
         ;; Finished chunked terminator (or a final framed write).
         (setf (handle-upload-frame h) nil
               (handle-upload-pos h) 0)
         (%begin-receive h))
        (t
         (setf (handle-upload-frame h) nil
               (handle-upload-pos h) 0)
         (%kick-write h)))))

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
       (if (handle-body-stream h)
           (progn
             (body-eof (handle-body-stream h))
             (bt:with-lock-held ((handle-lock h))
               (setf (handle-finished-p h) t))
             (%marshal h (lambda () (%cleanup h))))
           (let ((octets (apply #'concatenate '(vector (unsigned-byte 8))
                                (nreverse (or (handle-body-chunks h) '())))))
             (%finish-vector-body h octets))))
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

  (defun %should-follow-redirect-p (h status ht)
    (let ((location (gethash "location" ht)))
      (and location
           (redirect-status-p status)
           (plusp (handle-max-redirects h))
           (< (handle-redirect-hops h) (handle-max-redirects h)))))

  (defun %apply-ce (h body ht)
    "Decode CE for vector or wrap stream (Gray CE chain)."
    (let ((req (handle-http-request h)))
      (if (streamp body)
          (wrap-response-body-stream body ht
                                     :decompress (http-request-decompress req))
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
            (values decoded ht2)))))

  (defun %make-response (h body &key (history-for-final nil))
    (let* ((req (handle-http-request h))
           (uri (handle-uri h))
           (url (quri:render-uri uri))
           (ht (handle-headers-ht h))
           (jar (or (handle-cookie-jar h)
                    (resolve-cookie-jar (handle-client h) req :url url)))
           (cookies (merge-response-cookies jar url ht)))
      (multiple-value-bind (body* headers*)
          (%apply-ce h body ht)
        (make-instance 'http-response
                       :status (handle-status h)
                       :headers headers*
                       :body body*
                       :url url
                       :cookies cookies
                       :history history-for-final
                       :request req))))

  (defun %close-req-conn (h)
    (when-let (r (handle-req h))
      (%close-hinternet r)
      (setf (handle-req h) nil))
    (when-let (c (handle-conn h))
      (%close-hinternet c)
      (setf (handle-conn h) nil)))

  (defun %follow-redirect (h body-octets)
    "Push hop, prepare next request, reopen on the same session."
    (let* ((status (handle-status h))
           (ht (handle-headers-ht h))
           (location (gethash "location" ht))
           (jar (handle-cookie-jar h))
           (hop (%make-response h body-octets)))
      (push hop (handle-history h))
      (incf (handle-redirect-hops h))
      (handler-case
          (let ((next (resolve-redirect-uri (handle-uri h) location)))
            (when (and (streamp (handle-content h))
                       (redirect-preserves-method-p status))
              (error 'http-protocol-error
                     :message "cannot replay streamed request body on redirect"))
            (multiple-value-bind (method uri headers body)
                (prepare-redirect-hop status next
                                      (handle-method h)
                                      (or (handle-content h) #())
                                      (handle-headers h)
                                      jar
                                      (handle-accept-encoding h))
              (%close-req-conn h)
              (setf (handle-method h) method
                    (handle-uri h) uri
                    (handle-headers h) headers
                    (handle-content h) body
                    (handle-stream-body-p h) (streamp body)
                    (handle-body-stream-src h) (and (streamp body) body)
                    (handle-chunked-p h) nil
                    (handle-content-length h)
                    (and (not (streamp body)) (length (or body #())))
                    (handle-body-chunks h) nil
                    (handle-headers-ht h) nil
                    (handle-status h) nil
                    (handle-finished-p h) nil
                    (handle-headers-delivered-p h) nil)
              (%open-request-on-session h)))
        (error (e) (%fail h e)))))

  (defun %finish-vector-body (h octets)
    (let ((status (handle-status h))
          (ht (handle-headers-ht h)))
      (if (%should-follow-redirect-p h status ht)
          (%follow-redirect h octets)
          (%succeed h (%make-response
                       h octets
                       :history-for-final (nreverse (handle-history h)))))))

  (defun %on-headers (h)
    (let* ((req (handle-req h))
           (status (winhttp:query-status-code req))
           (ht (%headers-hash req)))
      (setf (handle-status h) status
            (handle-headers-ht h) ht)
      ;; Merge Set-Cookie even on hops we follow.
      (merge-response-cookies (handle-cookie-jar h)
                              (quri:render-uri (handle-uri h))
                              ht)
      ;; 401/407 auth — set credentials + resend (connection-oriented).
      (when (member status '(401 407))
        (when (answer-auth-challenge req status ht
                                     (handle-uri h)
                                     (handle-proxy-uri h)
                                     (handle-basic-auth h))
          (handler-case
              (progn
                (when (handle-stream-body-p h)
                  (error 'http-protocol-error
                         :message "cannot replay streamed request body on auth challenge"))
                (drain-response-body req)
                (let* ((content (or (handle-content h) #()))
                       (ok (winhttp:send-request req content)))
                  (unless (or ok (pending-p))
                    (winhttp::get-last-error))))
            (error (e) (%fail h e)))
          (return-from %on-headers)))
      (if (and (handle-want-stream-p h)
               (not (%should-follow-redirect-p h status ht)))
          (let ((stream (make-winhttp-body-input-stream
                         :on-space
                         (lambda ()
                           (when (handle-read-paused-p h)
                             (setf (handle-read-paused-p h) nil)
                             (%kick-read h))))))
            (setf (handle-body-stream h) stream)
            (%succeed h (%make-response
                         h stream
                         :history-for-final (nreverse (copy-list (handle-history h)))))
            (%kick-read h))
          (progn
            (setf (handle-body-chunks h) nil)
            (%kick-read h)))))

  (defun %reset-upload-state (h)
    (setf (handle-upload-frame h) nil
          (handle-upload-pos h) 0
          (handle-upload-done-p h) nil
          (handle-writing-body-p h) nil)
    (%free-upload-foreign h))

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
             (if (handle-stream-body-p h)
                 (%kick-write h)
                 (handler-case
                     (winhttp:receive-response (handle-req h))
                   (error (e) (%fail h e)))))
            (:write-complete
             ;; lpvStatusInformation → DWORD bytes written (not INFOLEN).
             (let ((n (if (and infop (not (cffi:null-pointer-p infop)))
                          (cffi:mem-ref infop :uint32)
                          infolen)))
               (%on-write-complete h n)))
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

  (defun %open-request-on-session (h)
    "Open conn+req on HANDLE-SESSION and SEND (async). Lisp cookies/redirects."
    (let* ((uri (handle-uri h))
           (method (handle-method h))
           (headers (handle-headers h))
           (content (handle-content h))
           (proxy-uri (handle-proxy-uri h))
           (https (string-equal (quri:uri-scheme uri) "https"))
           (host (strip-ipv6-brackets (quri:uri-host uri)))
           (port (or (quri:uri-port uri) (if https 443 80)))
           (session (handle-session h))
           (ctx (cffi:make-pointer (handle-id h)))
           (conn (winhttp:http-connect session host port)))
      (setf (handle-conn h) conn)
      (%reset-upload-state h)
      (let ((req (winhttp:http-open-request conn
                                            :verb method
                                            :url (%path-query uri)
                                            :https-p https)))
        (setf (handle-req h) req)
        ;; Disable WinHTTP cookies/redirects — Lisp owns jars + history.
        (set-option req +winhttp-option-disable-feature+
                    (logior +winhttp-disable-cookies+
                            +winhttp-disable-redirects+))
        (set-option req +winhttp-option-autologon-policy+
                    (autologon-policy-value))
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
        (when (and https (handle-insecure-p h))
          (ignore-errors (winhttp::set-ignore-certificates req)))
        (cond
          ((handle-stream-body-p h)
           ;; Headers only; body via WriteData after SENDREQUEST_COMPLETE.
           (let ((total (if (handle-chunked-p h)
                            +winhttp-ignore-request-total-length+
                            (or (handle-content-length h) 0))))
             (send-request-total req total)))
          (t
           (let* ((body (if (streamp content) #() (or content #())))
                  (ok (winhttp:send-request req body)))
             (unless (or ok (pending-p))
               (winhttp::get-last-error)))))
        h)))

  (defun %start-async-request (h uri method headers content
                               &key system-proxy-p proxy-uri insecure
                                 user-agent)
    (let* ((id (%register-handle h))
           (session (open-http-session (or user-agent "http-backend-winhttp/0.1")
                                       system-proxy-p :async t)))
      (setf (handle-session h) session
            (handle-uri h) uri
            (handle-method h) method
            (handle-headers h) headers
            (handle-content h) content
            (handle-proxy-uri h) proxy-uri
            (handle-system-proxy-p h) system-proxy-p
            (handle-insecure-p h) insecure
            (handle-user-agent h) user-agent)
      (when (and (handle-stream-body-p h) (null (handle-body-stream-src h)))
        (setf (handle-body-stream-src h) content))
      (winhttp:set-status-callback session (cffi:get-callback '%winhttp-status-cb))
      (%open-request-on-session h))))

#- (or win32 windows mswindows)
(defun %start-async-request (&rest args)
  (declare (ignore args))
  (error 'unsupported-operation :operation :winhttp
         :message "http-backend-winhttp requires Windows"))
