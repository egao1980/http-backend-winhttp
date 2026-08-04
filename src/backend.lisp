(in-package #:http-backend-winhttp)

;;; http-protocol backend: SEND-ASYNC (WinHTTP async) + blocking SEND await.

(defclass winhttp-backend (http-backend)
  ()
  (:default-initargs :name "winhttp"))

(defmethod backend-http-versions ((backend winhttp-backend))
  "WinHTTP can enable HTTP/2 (WINHTTP_PROTOCOL_FLAG_HTTP2) on Windows."
  (declare (ignore backend))
  #+(or win32 windows mswindows) '(:http/1.1 :http/2)
  #-(or win32 windows mswindows) '(:http/1.1))

(defvar *event-backend-maker* nil
  "Thunk → event-backend (libuv). Required for SEND-ASYNC marshaling.")

(defun make-winhttp-backend ()
  (unless (winhttp-available-p)
    (error 'unsupported-operation
           :operation 'make-winhttp-backend
           :message "http-backend-winhttp requires Windows + WinHTTP"))
  (make-instance 'winhttp-backend))

(defun %ensure-event-context ()
  (let ((eb (or *event-backend*
                (and *event-backend-maker* (funcall *event-backend-maker*))
                (error 'http-protocol-error
                       :message "WinHTTP async needs *EVENT-BACKEND* or *EVENT-BACKEND-MAKER* (libuv)")))
        (el (or *event-loop* (make-event-loop (or *event-backend*
                                                  (funcall *event-backend-maker*))))))
    (values eb el)))

(defun %header-alist (headers)
  (loop for pair in headers
        for name = (string-downcase (string (if (consp pair) (car pair) pair)))
        for value = (if (consp pair) (cdr pair) nil)
        when value
          collect (cons name (if (stringp value) value (princ-to-string value)))))

(defun %merge-headers (a b)
  (append (%header-alist a) (%header-alist b)))

(defun %accept-encoding-header (spec)
  (cond ((null spec) nil)
        ((member spec '(:default t) :test #'eq)
         (default-accept-encoding :as :string))
        ((stringp spec) spec)
        ((listp spec)
         (format nil "~{~(~A~)~^,~}"
                 (mapcar #'normalize-content-coding spec)))
        (t (string spec))))

(defun %basic-auth-cons (auth)
  (when (and (consp auth) (eq (first auth) :basic))
    (cons (second auth) (or (third auth) ""))))

(defmethod send-async ((backend winhttp-backend) client request
                       &key callback error-callback)
  (unless (winhttp-available-p)
    (error 'unsupported-operation :operation 'send-async
           :message "http-backend-winhttp requires Windows"))
  (let* ((cb (or callback (lambda (r) (declare (ignore r)))))
         (eb-cb (or error-callback (lambda (c) (error c))))
         (uri (quri:uri (http-request-url request)))
         (method (http-request-method request))
         (proxy-cfg (effective-proxy-config request client))
         (proxy-url (resolve-proxy proxy-cfg uri))
         (system-p (use-os-automatic-proxy-p proxy-cfg uri proxy-url))
         (proxy-uri (and proxy-url (quri:uri proxy-url)))
         (want-stream (http-request-want-stream request)))
    (when (and proxy-uri (socks-proxy-scheme-p (quri:uri-scheme proxy-uri)))
      (error 'unsupported-operation
             :operation :socks-proxy
             :message "WinHTTP does not support SOCKS; use http-backend-async"))
    (multiple-value-bind (event-backend event-loop) (%ensure-event-context)
      (let* ((headers (%merge-headers (http-client-headers client)
                                      (http-request-headers request)))
             (ae (%accept-encoding-header
                  (http-request-accept-encoding request)))
             (auth (effective-auth client request))
             (jar (resolve-cookie-jar client request
                                      :url (http-request-url request)))
             (max-redirects (or (http-request-max-redirects request)
                                (http-client-max-redirects client)
                                5)))
        (setf headers (inject-auth-range-headers
                       headers :auth auth :range (http-request-range request)))
        (when ae
          (setf headers (acons "accept-encoding" ae
                               (remove "accept-encoding" headers
                                       :key #'car :test #'string-equal))))
        (setf headers (inject-cookie-header headers jar
                                            (quri:render-uri uri)))
        (multiple-value-bind (content extra-headers content-length)
            (prepare-request-body request)
          (dolist (pair extra-headers)
            (setf headers (acons (car pair) (cdr pair)
                                 (remove (car pair) headers
                                         :key #'car :test #'string-equal))))
          (multiple-value-bind (wire headers* stream-p chunked-p clen)
              (normalize-request-wire content headers content-length)
            (let ((handle
                   (make-instance 'winhttp-request-handle
                                  :event-backend event-backend
                                  :event-loop event-loop
                                  :callback cb
                                  :error-callback eb-cb
                                  :want-stream want-stream
                                  :request request
                                  :client client
                                  :basic-auth (%basic-auth-cons auth)
                                  :cookie-jar jar
                                  :max-redirects max-redirects
                                  :accept-encoding ae
                                  :headers headers*
                                  :stream-body-p stream-p
                                  :chunked-p chunked-p
                                  :content-length clen
                                  :body-stream-src (and stream-p wire)
                                  :content wire)))
              (%start-async-request handle uri method headers* wire
                                    :system-proxy-p system-p
                                    :proxy-uri proxy-uri
                                    :insecure (not (http-client-verify client)))
              handle)))))))
(defun apply-stream-upload-headers (headers content-length)
  "Set Content-Length or Transfer-Encoding: chunked for a streamed upload.
   Returns (values headers chunked-p)."
  (let* ((chunked-p (null content-length))
         (headers (if content-length
                      (acons "content-length"
                             (princ-to-string content-length)
                             (remove "content-length" headers
                                     :key #'car :test #'string-equal))
                      (remove "content-length" headers
                              :key #'car :test #'string-equal)))
         (headers (if chunked-p
                      (if (assoc "transfer-encoding" headers :test #'string-equal)
                          headers
                          (acons "transfer-encoding" "chunked" headers))
                      headers)))
    (values headers chunked-p)))

(defun normalize-request-wire (content headers content-length)
  "Wire body for WinHTTP: vector (buffered) or stream (WriteData).
   Returns (values wire headers stream-p chunked-p content-length)."
  (cond
    ((streamp content)
     (multiple-value-bind (headers* chunked-p)
         (apply-stream-upload-headers headers content-length)
       (values content headers* t chunked-p content-length)))
    (t
     (let ((octets (cond
                     ((null content) #())
                     ((typep content '(vector (unsigned-byte 8))) content)
                     ((stringp content)
                      (babel:string-to-octets content :encoding :utf-8))
                     ((and (vectorp content) (every #'integerp content))
                      (coerce content '(simple-array (unsigned-byte 8) (*))))
                     (t (error 'http-protocol-error
                               :message
                               (format nil "unsupported request body type ~S"
                                       (type-of content)))))))
       (values octets headers nil nil (length octets))))))

(defmethod cancel-request ((backend winhttp-backend) handle)
  (check-type handle winhttp-request-handle)
  (%close-for-cancel handle)
  handle)

(defmethod send ((backend winhttp-backend) client request &key)
  "Blocking SEND = await SEND-ASYNC on the event loop (+ http-retry)."
  (multiple-value-bind (event-backend event-loop) (%ensure-event-context)
    (let* ((retry (effective-retry request client))
           (timeout (effective-timeout request client))
           (total-s (or (and timeout (timeout-total-seconds timeout)) 30.0))
           (attempts (1+ (or (and retry (retry-total retry)) 0)))
           (last-err nil))
      (dotimes (i attempts (if last-err (error last-err)
                               (error 'http-timeout-error
                                      :message "winhttp send failed")))
        (let ((result nil)
              (err nil)
              (done nil))
          (labels ((finish (res)
                     (setf result res done t)
                     (stop event-backend event-loop))
                   (fail (c)
                     (setf err c done t)
                     (stop event-backend event-loop)))
            (with-event-backend (event-backend)
              (with-event-loop-var (event-loop)
                (send-async backend client request
                            :callback #'finish :error-callback #'fail)
                (apply #'sleep* event-backend event-loop total-s
                       (list :callback
                             (lambda ()
                               (unless done
                                 (fail (make-condition
                                        'http-timeout-error
                                        :message "winhttp send timed out"))))))
                (run event-backend event-loop :stop-when-idle nil))))
          (cond
            (result (return-from send result))
            ((and err retry
                  (plusp (or (retry-total retry) 0))
                  (< i (1- attempts)))
             (setf last-err err)
             (sleep (or (ignore-errors (retry-delay-seconds retry i)) 0.5)))
            (err (error err))))))))
